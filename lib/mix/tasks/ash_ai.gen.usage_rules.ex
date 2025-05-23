defmodule Mix.Tasks.AshAi.Gen.UsageRules.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc do
    "Combine the package rules for the provided packages into the provided file, or list/gather all dependencies."
  end

  @spec example() :: String.t()
  def example do
    "mix ash_ai.gen.usage_rules rules.md ash ash_postgres phoenix"
  end

  @spec long_doc() :: String.t()
  def long_doc do
    """
    #{short_doc()}

    ## Options

    * `--all` - Gather usage rules from all dependencies that have them
    * `--list` - List all dependencies with usage rules. If a file is provided, shows status (present, missing, stale)

    ## Examples

    Combine specific packages:
    ```sh
    #{example()}
    ```

    Gather all dependencies with usage rules:
    ```sh
    mix ash_ai.gen.usage_rules rules.md --all
    ```

    List all dependencies with usage rules:
    ```sh
    mix ash_ai.gen.usage_rules --list
    ```

    Check status of dependencies against a specific file:
    ```sh
    mix ash_ai.gen.usage_rules rules.md --list
    ```
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshAi.Gen.UsageRules do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        # Groups allow for overlapping arguments for tasks by the same author
        # See the generators guide for more.
        group: :ash_ai,
        example: __MODULE__.Docs.example(),
        positional: [
          file: [optional: true],
          packages: [rest: true, optional: true]
        ],
        schema: [
          all: :boolean,
          list: :boolean
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      all_deps = Mix.Project.deps_paths()
      all_option = igniter.args.options[:all]
      list_option = igniter.args.options[:list]
      provided_packages = igniter.args.positional.packages

      cond do
        # If --list or --all is given and packages list is not empty, add error
        (all_option || list_option) && !Enum.empty?(provided_packages) ->
          Igniter.add_issue(igniter, "Cannot specify packages when using --all or --list options")

        # If no packages are given and neither --list nor --all is set, add error
        Enum.empty?(provided_packages) && !all_option && !list_option ->
          add_usage_error(igniter)

        # If --all is used without a file, add error
        all_option && is_nil(igniter.args.positional[:file]) ->
          Igniter.add_issue(igniter, "--all option requires a file to write to")

        # Handle --all option
        all_option ->
          handle_all_option(igniter, all_deps)

        # Handle --list option
        list_option ->
          handle_list_option(igniter, all_deps)

        # Handle specific packages
        true ->
          handle_specific_packages(igniter, all_deps, provided_packages)
      end
    end

    defp add_usage_error(igniter) do
      Igniter.add_issue(igniter, """
      Usage:
        mix ash_ai.gen.usage_rules <file> <packages...>
          Combine specific packages' usage rules into the target file

        mix ash_ai.gen.usage_rules <file> --all
          Gather usage rules from all dependencies into the target file

        mix ash_ai.gen.usage_rules [file] --list
          List packages with usage rules (optionally check status against file)
      """)
    end

    defp handle_all_option(igniter, all_deps) do
      all_packages_with_rules = get_packages_with_usage_rules(all_deps)

      igniter
      |> Igniter.add_notice("Found #{length(all_packages_with_rules)} dependencies with usage rules")
      |> then(fn igniter ->
        Enum.reduce(all_packages_with_rules, igniter, fn {name, _path}, acc ->
          Igniter.add_notice(acc, "Including usage rules for: #{name}")
        end)
      end)
      |> generate_usage_rules_file(all_packages_with_rules)
    end

    defp handle_list_option(igniter, all_deps) do
      packages_with_rules = get_packages_with_usage_rules(all_deps)

      if Enum.empty?(packages_with_rules) do
        Igniter.add_notice(igniter, "No packages found with usage-rules.md files")
      else
        file_path = igniter.args.positional[:file]
        
        if file_path do
          list_packages_with_file_comparison(igniter, packages_with_rules, file_path)
        else
          list_packages_without_comparison(igniter, packages_with_rules)
        end
      end
    end

    defp handle_specific_packages(igniter, all_deps, provided_packages) do
      packages =
        all_deps
        |> Enum.filter(fn {name, _path} ->
          to_string(name) in provided_packages
        end)
        |> Enum.flat_map(fn {name, path} ->
          path
          |> Path.join("usage-rules.md")
          |> File.exists?()
          |> case do
            true ->
              [{name, path}]

            false ->
              []
          end
        end)

      generate_usage_rules_file(igniter, packages)
    end

    defp get_packages_with_usage_rules(all_deps) do
      all_deps
      |> Enum.filter(fn {_name, path} ->
        path
        |> Path.join("usage-rules.md")
        |> File.exists?()
      end)
    end

    defp list_packages_with_file_comparison(igniter, packages_with_rules, file_path) do
      current_file_content = read_current_file_content(igniter, file_path)

      Enum.reduce(packages_with_rules, igniter, fn {name, path}, acc ->
        package_rules_content = File.read!(Path.join(path, "usage-rules.md"))
        
        status = get_package_status_in_file(name, package_rules_content, current_file_content)
        colored_status = colorize_status(status)
        Igniter.add_notice(acc, "#{name}: #{colored_status}")
      end)
    end

    defp list_packages_without_comparison(igniter, packages_with_rules) do
      Enum.reduce(packages_with_rules, igniter, fn {name, _path}, acc ->
        Igniter.add_notice(acc, "#{name}: #{IO.ANSI.green()}has usage rules#{IO.ANSI.reset()}")
      end)
    end

    defp read_current_file_content(igniter, file_path) do
      if Igniter.exists?(igniter, file_path) do
        case Rewrite.source(igniter.rewrite, file_path) do
          {:ok, source} -> Rewrite.Source.get(source, :content)
          {:error, _} -> 
            case File.read(file_path) do
              {:ok, content} -> content
              {:error, _} -> ""
            end
        end
      else
        ""
      end
    end

    defp generate_usage_rules_file(igniter, packages) do
      package_contents =
        packages
        |> Enum.map(fn {name, path} ->
          {name,
           "<-- #{name}-start -->\n" <>
             "## #{name} usage\n" <>
             File.read!(Path.join(path, "usage-rules.md")) <>
             "\n<-- #{name}-end -->"}
        end)

      contents =
        "<-- package-rules-start -->\n" <>
          Enum.map_join(package_contents, "\n", &elem(&1, 1)) <> "\n<-- package-rules-end -->"

      Igniter.create_or_update_file(
        igniter,
        igniter.args.positional[:file],
        contents,
        fn source ->
          current_contents = Rewrite.Source.get(source, :content)

          new_content =
            case String.split(current_contents, [
                   "<-- package-rules-start -->\n",
                   "\n<-- package-rules-end -->"
                 ]) do
              [prelude, current_packages_contents, postlude] ->
                Enum.reduce(package_contents, current_packages_contents, fn {name, package_content},
                                                                    acc ->
                  case String.split(acc, [
                         "<-- #{name}-start -->\n",
                         "\n<-- #{name}-end -->"
                       ]) do
                    [prelude, _, postlude] ->
                      prelude <> package_content <> postlude

                    _ ->
                      acc <> "\n" <> package_content
                  end
                end)
                |> then(fn content ->
                  prelude <>
                    "<-- package-rules-start -->\n" <>
                    content <>
                    "\n<-- package-rules-end -->\n" <>
                    postlude
                end)

              _ ->
                current_contents <>
                  "\n<-- package-rules-start -->\n" <>
                  contents <>
                  "\n<-- package-rules-end -->\n"
            end

          Rewrite.Source.update(source, :content, new_content)
        end
      )
    end

    defp get_package_status_in_file(name, package_rules_content, file_content) do
      package_start_marker = "<-- #{name}-start -->"
      package_end_marker = "<-- #{name}-end -->"
      
      case String.split(file_content, [package_start_marker, package_end_marker]) do
        [_, current_package_content, _] ->
          # Package is present in file, check if content matches
          expected_content = "\n## #{name} usage\n" <> package_rules_content <> "\n"
          if String.trim(current_package_content) == String.trim(expected_content) do
            "present"
          else
            "stale"
          end
        _ ->
          # Package not found in file
          "missing"
      end
    end

    defp colorize_status("present"), do: "#{IO.ANSI.green()}present#{IO.ANSI.reset()}"
    defp colorize_status("stale"), do: "#{IO.ANSI.yellow()}stale#{IO.ANSI.reset()}"
    defp colorize_status("missing"), do: "#{IO.ANSI.red()}missing#{IO.ANSI.reset()}"
  end
else
  defmodule Mix.Tasks.AshAi.Gen.UsageRules do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_ai.gen.package_rules' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
