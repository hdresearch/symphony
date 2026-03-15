defmodule SymphonyElixir.VersAgentRunner do
  @moduledoc """
  Executes a Linear issue inside a Vers VM using the `pi` coding agent.
  
  This is an alternative to the local Codex-based AgentRunner that provides
  full VM isolation for each agent run. Uses vers CLI directly.
  
  The golden commit should have API keys baked in via /root/symphony_env.sh
  which is sourced from .bashrc. See README.md for setup instructions.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker}

  # Poll every 60 seconds since vers execute takes ~30s each
  @output_poll_interval_ms 60_000

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    # DEBUG: Write to file immediately
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} VersAgentRunner.run called\n", [:append])
    IO.puts(:stderr, "[VersAgent DEBUG] run() called")
    Logger.info("[VersAgent] Starting agent run for #{issue_context(issue)}")

    prompt = PromptBuilder.build_prompt(issue, opts)
    golden_commit = get_golden_commit()
    max_runtime_ms = Config.settings!().vers.max_runtime_ms || 1_800_000

    # Debug log - early
    File.write("/tmp/vers_debug.log", 
      "#{DateTime.utc_now()} About to create VM from golden commit: #{golden_commit}\n", 
      [:append])
    
    # Create VM from golden commit
    case create_vm(golden_commit) do
      {:ok, vm_id} ->
        Logger.info("[VersAgent] Created VM #{short_id(vm_id)} for #{issue_context(issue)}")
        File.write("/tmp/vers_debug.log", 
          "#{DateTime.utc_now()} VM created: #{vm_id}\n", 
          [:append])
        
        send_update(update_recipient, issue, %{
          event: :session_started,
          session_id: vm_id,
          timestamp: DateTime.utc_now()
        })

        try do
          run_agent_in_vm(vm_id, prompt, issue, update_recipient, max_runtime_ms, opts)
        after
          delete_vm(vm_id)
          Logger.info("[VersAgent] Deleted VM #{short_id(vm_id)}")
        end

      {:error, reason} ->
        Logger.error("[VersAgent] Failed to create VM: #{inspect(reason)}")
        raise RuntimeError, "Failed to create Vers VM: #{inspect(reason)}"
    end
  end

  defp run_agent_in_vm(vm_id, prompt, issue, update_recipient, max_runtime_ms, opts) do
    # Debug log - write to stderr and file
    IO.puts(:stderr, "[VersAgent DEBUG] run_agent_in_vm starting for #{vm_id}")
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} run_agent_in_vm starting for #{vm_id}\n", [:append])
    Logger.warning("[VersAgent DEBUG] run_agent_in_vm starting for #{vm_id}")
    
    # Write the prompt to a file using vers scp, then run pi reading from that file
    # This avoids all shell escaping issues with complex multi-line prompts
    
    # Step 1: Write prompt to a local temp file
    local_prompt_file = "/tmp/pi_prompt_#{vm_id}.txt"
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} About to write prompt to #{local_prompt_file}\n", [:append])
    File.write!(local_prompt_file, prompt)
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Prompt file created\n", [:append])
    
    # Step 2: Copy prompt file to VM using vers scp
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} About to call vers_scp_to\n", [:append])
    
    case vers_scp_to(vm_id, local_prompt_file, "/tmp/pi_prompt.txt") do
      :ok ->
        File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Prompt copy OK, cleaning up local file\n", [:append])
        # Clean up local temp file
        File.rm(local_prompt_file)
        
        # Step 3: Start pi with the prompt file, sourcing env first
        # Source the env file directly before running pi to ensure API keys are available
        start_cmd = "nohup bash -c 'source /root/symphony_env.sh && pi -p \"$(cat /tmp/pi_prompt.txt)\"' > /tmp/pi_output.txt 2>&1 & echo $!"
        
        File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Calling vers_execute to start pi\n", [:append])
        
        case vers_execute(vm_id, start_cmd, 300) do
          {:ok, pid_output} ->
            _pi_pid = String.trim(pid_output)
            File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Pi started with PID #{String.trim(pid_output)}\n", [:append])
            
            issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
            monitor_execution(vm_id, issue, update_recipient, issue_state_fetcher, max_runtime_ms)

          {:error, reason} ->
            Logger.error("[VersAgent] Failed to start pi: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        File.rm(local_prompt_file)
        Logger.error("[VersAgent] Failed to copy prompt file to VM: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp monitor_execution(vm_id, issue, update_recipient, issue_state_fetcher, max_runtime_ms) do
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} monitor_execution starting\n", [:append])
    start_time = System.monotonic_time(:millisecond)
    monitor_loop(vm_id, issue, update_recipient, issue_state_fetcher, start_time, max_runtime_ms, 0)
  end

  defp monitor_loop(vm_id, issue, update_recipient, issue_state_fetcher, start_time, max_runtime_ms, last_size) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} monitor_loop elapsed=#{elapsed}ms\n", [:append])

    cond do
      elapsed > max_runtime_ms ->
        Logger.warning("[VersAgent] VM #{short_id(vm_id)} exceeded max runtime")
        send_update(update_recipient, issue, %{
          event: :error,
          session_id: vm_id,
          timestamp: DateTime.utc_now(),
          error: "timeout"
        })
        :ok

      !issue_still_active?(issue, issue_state_fetcher) ->
        Logger.info("[VersAgent] Issue #{issue_context(issue)} no longer active, stopping")
        :ok

      true ->
        case check_status_and_output(vm_id, last_size) do
          {:running, new_output, new_size} ->
            # Always send an update to keep the orchestrator's stall timer happy
            # Use :output event with the new content, or :heartbeat if no new content
            if new_output != "" do
              send_update(update_recipient, issue, %{
                event: :output,
                session_id: vm_id,
                timestamp: DateTime.utc_now(),
                message: String.slice(new_output, -200, 200)
              })
            else
              # Send heartbeat to prevent stall detection
              send_update(update_recipient, issue, %{
                event: :output,
                session_id: vm_id,
                timestamp: DateTime.utc_now(),
                message: "Agent still running..."
              })
            end
            
            Process.sleep(@output_poll_interval_ms)
            monitor_loop(vm_id, issue, update_recipient, issue_state_fetcher, start_time, max_runtime_ms, new_size)

          {:completed, output} ->
            File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Agent completed! Output length: #{byte_size(output)}\n", [:append])
            Logger.info("[VersAgent] Agent completed in VM #{short_id(vm_id)}")
            
            # Post the agent's output as a comment on the Linear issue
            comment_body = """
            ## Agent Output

            #{String.trim(output)}

            ---
            *Completed by Symphony agent*
            """
            
            case Tracker.create_comment(issue.id, comment_body) do
              :ok ->
                File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Posted output as comment\n", [:append])
                Logger.info("[VersAgent] Posted output as comment on #{issue.identifier}")
              {:error, reason} ->
                File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Failed to post comment: #{inspect(reason)}\n", [:append])
                Logger.warning("[VersAgent] Failed to post comment: #{inspect(reason)}")
            end
            
            # Update Linear issue to Done
            case Tracker.update_issue_state(issue.id, "Done") do
              :ok ->
                File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Linear issue marked as Done\n", [:append])
                Logger.info("[VersAgent] Linear issue #{issue.identifier} marked as Done")
              {:error, reason} ->
                File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} Failed to mark issue as Done: #{inspect(reason)}\n", [:append])
                Logger.warning("[VersAgent] Failed to update Linear: #{inspect(reason)}")
            end
            
            send_update(update_recipient, issue, %{
              event: :turn_completed,
              session_id: vm_id,
              timestamp: DateTime.utc_now(),
              message: "Agent completed"
            })
            :ok

          {:error, reason} ->
            Logger.error("[VersAgent] Error checking VM: #{inspect(reason)}")
            send_update(update_recipient, issue, %{
              event: :error,
              session_id: vm_id,
              timestamp: DateTime.utc_now(),
              error: inspect(reason)
            })
            :ok
        end
    end
  end

  defp check_status_and_output(vm_id, last_size) do
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} check_status_and_output called\n", [:append])
    
    # Check if pi is still running by looking for node processes
    # We use ps + grep with a pattern that won't match itself
    # The [n]ode trick prevents grep from matching itself
    case vers_execute(vm_id, "ps aux | grep -E '[n]ode.*pi|[p]i.*--' | grep -v grep > /dev/null 2>&1 && echo running || echo done", 120) do
      {:ok, output} ->
        running = String.contains?(output, "running")
        File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} process check: running=#{running}\n", [:append])
        
        # Get output
        case vers_execute(vm_id, "cat /tmp/pi_output.txt 2>/dev/null", 300) do
          {:ok, full_output} ->
            new_size = byte_size(full_output)
            new_content = if new_size > last_size do
              binary_part(full_output, last_size, new_size - last_size)
            else
              ""
            end
            
            if running do
              {:running, new_content, new_size}
            else
              {:completed, full_output}
            end

          {:error, _reason} ->
            # If we can't read output, assume still running
            Logger.warning("[VersAgent] Failed to read output, assuming still running")
            {:running, "", last_size}
        end

      {:error, _reason} ->
        # If process check fails, don't error out - just assume still running
        # This handles transient API timeouts gracefully
        Logger.warning("[VersAgent] Process check failed, assuming still running")
        {:running, "", last_size}
    end
  end

  # Vers CLI commands

  defp create_vm(golden_commit) do
    case System.cmd("vers", ["run-commit", golden_commit], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/VM '([0-9a-f-]{36})'/, output) do
          [_, vm_id] -> {:ok, vm_id}
          _ -> {:error, {:parse_error, output}}
        end

      {output, code} ->
        {:error, {:exit_code, code, output}}
    end
  end

  defp vers_execute(vm_id, command, timeout_secs) do
    args = ["execute", vm_id, "-t", to_string(timeout_secs), "--", "bash", "-c", command]
    Logger.debug("[VersAgent] Executing: vers #{Enum.join(args, " ")}")
    
    case System.cmd("vers", args, stderr_to_stdout: true) do
      {output, 0} -> 
        Logger.debug("[VersAgent] Command succeeded")
        {:ok, output}
      {output, code} -> 
        Logger.debug("[VersAgent] Command failed with code #{code}: #{String.slice(output, 0, 200)}")
        {:error, {:exit_code, code, output}}
    end
  end

  defp vers_scp_to(vm_id, local_path, remote_path) do
    File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} vers_scp_to start\n", [:append])
    # vers copy is unreliable (times out frequently), so we use vers execute 
    # with base64 encoding to transfer the file contents instead
    case File.read(local_path) do
      {:ok, content} ->
        # Base64 encode the content to safely transfer it
        encoded = Base.encode64(content)
        File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} encoded size=#{byte_size(encoded)}\n", [:append])
        
        # Write the file via vers execute using base64 decode
        # Split into chunks if too large for command line
        cmd = "echo '#{encoded}' | base64 -d > #{remote_path}"
        File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} calling vers_execute with 300s timeout\n", [:append])
        
        case vers_execute(vm_id, cmd, 300) do
          {:ok, _} -> 
            File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} vers_scp_to succeeded\n", [:append])
            :ok
          {:error, reason} -> 
            File.write!("/tmp/vers_debug.log", "#{DateTime.utc_now()} vers_scp_to failed: #{inspect(reason)}\n", [:append])
            {:error, reason}
        end
        
      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp delete_vm(vm_id) do
    System.cmd("vers", ["delete", "-y", vm_id], stderr_to_stdout: true)
    :ok
  end

  defp get_golden_commit do
    Config.settings!().vers.golden_commit ||
      System.get_env("VERS_GOLDEN_COMMIT") ||
      raise "No golden commit configured. Set vers.golden_commit in WORKFLOW.md"
  end

  defp issue_still_active?(%Issue{id: issue_id}, issue_state_fetcher) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{state: state} | _]} -> active_state?(state)
      _ -> false
    end
  end

  defp active_state?(state) when is_binary(state) do
    normalized = String.downcase(String.trim(state))
    Config.settings!().tracker.active_states
    |> Enum.any?(fn s -> String.downcase(String.trim(s)) == normalized end)
  end
  defp active_state?(_), do: false

  defp send_update(nil, _, _), do: :ok
  defp send_update(recipient, %Issue{id: issue_id}, update) when is_pid(recipient) do
    Logger.debug("[VersAgent] Sending update to orchestrator: event=#{update.event}")
    send(recipient, {:codex_worker_update, issue_id, update})
  end
  defp send_update(_, _, _), do: :ok

  defp issue_context(%Issue{id: id, identifier: ident}), do: "#{ident} (#{id})"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "?"
end
