#!/usr/bin/env elixir

defmodule SafeExpression.ReleaseError do
  defexception [:message]
end

defmodule SafeExpression.Release do
  alias SafeExpression.ReleaseError

  @branch "main"
  @remote "origin"
  @mix_file "mix.exs"
  @readme_file "README.md"

  def main([version]) do
    release!(version)
  rescue
    error in ReleaseError ->
      IO.puts(:stderr, "release failed: #{error.message}")
      System.halt(1)
  end

  def main(_arguments) do
    IO.puts(:stderr, "usage: scripts/release.exs VERSION\nexample: scripts/release.exs 0.2.0")
    System.halt(2)
  end

  defp release!(version) do
    validate_version!(version)
    ensure_repository_root!()
    ensure_branch!()
    ensure_clean_worktree!()

    run!("git", ["fetch", @remote, @branch, "--tags"])

    tag = "v#{version}"
    head = git_capture!(["rev-parse", "HEAD"])
    remote_head = git_capture!(["rev-parse", "#{@remote}/#{@branch}"])
    mix_contents = File.read!(@mix_file)
    readme_contents = File.read!(@readme_file)
    current_version = current_version!(mix_contents)

    case release_state(version, current_version, tag, head, remote_head) do
      :already_released ->
        IO.puts("#{tag} is already on #{@remote}/#{@branch}; nothing to do.")

      :resume ->
        resume_release!(tag, head, remote_head)

      :new ->
        create_release!(
          version,
          current_version,
          tag,
          head,
          remote_head,
          mix_contents,
          readme_contents
        )
    end
  end

  defp create_release!(
         version,
         current_version,
         tag,
         head,
         remote_head,
         mix_contents,
         readme_contents
       ) do
    unless Version.compare(version, current_version) == :gt do
      fail!("version #{version} must be newer than #{current_version}")
    end

    unless head == remote_head do
      fail!("local #{@branch} must match #{@remote}/#{@branch} before releasing")
    end

    if local_tag?(tag) or remote_tag?(tag) do
      fail!("tag #{tag} already exists")
    end

    updated_mix =
      replace_once!(
        mix_contents,
        "@version \"#{current_version}\"",
        "@version \"#{version}\"",
        @mix_file
      )

    updated_readme =
      readme_contents
      |> replace_once!("~> #{current_version}", "~> #{version}", @readme_file)
      |> replace_once!("tag: \"v#{current_version}\"", "tag: \"#{tag}\"", @readme_file)

    File.write!(@mix_file, updated_mix)
    File.write!(@readme_file, updated_readme)

    run!("git", ["add", @mix_file, @readme_file])
    run!("git", ["commit", "-m", "Release #{tag}"])
    run!("git", ["tag", "-a", tag, "-m", "Release #{tag}"])
    push_release!(tag)
  end

  defp release_state(version, current_version, tag, head, remote_head) do
    cond do
      version != current_version ->
        :new

      release_commit?(tag, head) and head == remote_head and remote_tag?(tag) ->
        :already_released

      release_commit?(tag, head) and release_parent?(head, remote_head) ->
        :resume

      true ->
        fail!(
          "#{@mix_file} already contains #{version}, but HEAD is not a resumable #{tag} release"
        )
    end
  end

  defp resume_release!(tag, head, remote_head) do
    cond do
      local_tag?(tag) and git_capture!(["rev-list", "-n", "1", tag]) != head ->
        fail!("local tag #{tag} does not point to the release commit")

      not local_tag?(tag) ->
        run!("git", ["tag", "-a", tag, "-m", "Release #{tag}"])

      true ->
        :ok
    end

    if head == remote_head do
      run!("git", ["push", @remote, tag])
    else
      push_release!(tag)
    end
  end

  defp push_release!(tag) do
    run!("git", ["push", "--atomic", @remote, @branch, tag])
    IO.puts("Released #{tag}. GitHub Actions will publish it after CI passes.")
  end

  defp release_commit?(tag, head) do
    git_capture!(["log", "-1", "--format=%s", head]) == "Release #{tag}"
  end

  defp release_parent?(head, remote_head) do
    case command("git", ["rev-parse", "#{head}^"]) do
      {parent, 0} -> String.trim(parent) == remote_head
      {_output, _status} -> false
    end
  end

  defp validate_version!(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if to_string(parsed) == version do
          :ok
        else
          fail!("#{inspect(version)} is not a canonical semantic version such as 0.2.0")
        end

      :error ->
        fail!("#{inspect(version)} is not a canonical semantic version such as 0.2.0")
    end
  end

  defp ensure_repository_root! do
    root = git_capture!(["rev-parse", "--show-toplevel"])

    unless Path.expand(root) == File.cwd!() do
      fail!("run this script from the repository root: #{root}")
    end
  end

  defp ensure_branch! do
    branch = git_capture!(["branch", "--show-current"])

    unless branch == @branch do
      fail!("releases must be created from #{@branch}; current branch is #{inspect(branch)}")
    end
  end

  defp ensure_clean_worktree! do
    case git_capture!(["status", "--porcelain"]) do
      "" -> :ok
      _changes -> fail!("working tree must be clean before releasing")
    end
  end

  defp current_version!(contents) do
    case Regex.scan(~r/^\s*@version\s+"([^"]+)"\s*$/m, contents, capture: :all_but_first) do
      [[version]] ->
        case Version.parse(version) do
          {:ok, _parsed} -> version
          :error -> fail!("#{@mix_file} contains invalid version #{inspect(version)}")
        end

      matches ->
        fail!("expected exactly one @version in #{@mix_file}, found #{length(matches)}")
    end
  end

  defp replace_once!(contents, old, new, path) do
    case :binary.matches(contents, old) do
      [_match] ->
        String.replace(contents, old, new)

      matches ->
        fail!("expected exactly one #{inspect(old)} in #{path}, found #{length(matches)}")
    end
  end

  defp local_tag?(tag) do
    match?({_output, 0}, command("git", ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"]))
  end

  defp remote_tag?(tag) do
    case command("git", ["ls-remote", "--exit-code", "--tags", @remote, "refs/tags/#{tag}"]) do
      {_output, 0} ->
        true

      {_output, 2} ->
        false

      {output, status} ->
        fail!("could not inspect remote tag #{tag} (exit #{status}): #{String.trim(output)}")
    end
  end

  defp git_capture!(arguments) do
    case command("git", arguments) do
      {output, 0} ->
        String.trim(output)

      {output, status} ->
        fail!("git #{Enum.join(arguments, " ")} failed (exit #{status}): #{String.trim(output)}")
    end
  end

  defp run!(executable, arguments) do
    IO.puts("$ #{Enum.join([executable | arguments], " ")}")

    case command(executable, arguments) do
      {output, 0} ->
        IO.write(output)
        output

      {output, status} ->
        IO.write(:stderr, output)
        fail!("#{executable} #{Enum.join(arguments, " ")} failed with exit code #{status}")
    end
  end

  defp command(executable, arguments) do
    System.cmd(executable, arguments, stderr_to_stdout: true)
  end

  defp fail!(message), do: raise(ReleaseError, message: message)
end

SafeExpression.Release.main(System.argv())
