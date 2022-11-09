defmodule Distillery.Releases.Assembler do
  @moduledoc """
  This module is responsible for assembling a release based on a `Distillery.Releases.Config`
  struct. It creates the release directory, copies applications, and generates release-specific
  files required by `:systools` and `:release_handler`.
  """
  alias Distillery.Releases.Config
  alias Distillery.Releases.Release
  alias Distillery.Releases.Utils
  alias Distillery.Releases.Environment
  # alias Distillery.Releases.Shell
  alias Distillery.Releases.Appup

  require Logger

  @doc false
  @spec pre_assemble(Config.t()) :: {:ok, Release.t()} | {:error, term}
  def pre_assemble(%Config{} = config) do
    with {:ok, environment} <- Release.select_environment(config),
         {:ok, release} <- Release.select_release(config),
         release <- apply_environment(release, environment),
        #  {:ok, release} <- Plugin.before_assembly(release),
         {:ok, release} <- Release.apply_configuration(release, config, true),
        #  :ok <- Release.validate(release),
         :ok <- make_paths(release) do
      {:ok, release}
    end
  end

  # Applies the environment profile to the release profile.
  @spec apply_environment(Release.t(), Environment.t()) :: Release.t()
  def apply_environment(%Release{} = r, %Environment{} = e) do
    Logger.info("Building release #{r.name}:#{r.version} using environment #{e.name}")
    Release.apply_environment(r, e)
  end

  # Creates release metadata files
  def write_release_metadata(%Release{name: name} = release) do
    resource_path =
      release
      |> Release.version_path()
      |> Path.join("#{name}.rel")

    with :ok <- Utils.write_term(resource_path, Release.to_resource(release)),
         :ok <- generate_relup(release) do
      :ok
    end
  end

  def generate_relup(%{name: name, upgrade_from: upfrom} = release) do
    IO.inspect(name)
    IO.inspect(upfrom)

    rel_dir = Release.version_path(release)
    # rel_dir = release_version_path(release)
    output_dir = release.profile.output_dir

    Logger.debug("Generating relup for #{name}")

    v1_rel = Path.join([output_dir, "releases", upfrom, "#{name}.rel"])
    v2_rel = Path.join(rel_dir, "#{name}.rel")

    case {File.exists?(v1_rel), File.exists?(v2_rel)} do
      {false, true} ->
        {:error, {:assembler, {:missing_rel, name, upfrom, v1_rel}}}

      {true, false} ->
        {:error, {:assembler, {:missing_rel, name, release.version, v2_rel}}}

      {false, false} ->
        {:error, {:assembler, {:missing_rels, name, upfrom, release.version, v1_rel, v2_rel}}}

      {true, true} ->
        v1_apps = extract_relfile_apps(v1_rel)
        v2_apps = extract_relfile_apps(v2_rel)
        changed = get_changed_apps(v1_apps, v2_apps)
        added = get_added_apps(v2_apps, changed)
        removed = get_removed_apps(v1_apps, v2_apps)

        case generate_appups(release, changed, output_dir) do
          {:error, _} = err ->
            IO.inspect(err, label: "error !")
            err

          :ok ->
            current_rel = Path.join([output_dir, "releases", release.version, "#{name}"])
            upfrom_rel = Path.join([output_dir, "releases", release.upgrade_from, "#{name}"])

            result =
              :systools.make_relup(
                String.to_charlist(current_rel),
                [String.to_charlist(upfrom_rel)],
                [String.to_charlist(upfrom_rel)],
                [
                  {:outdir, String.to_charlist(rel_dir)},
                  {:path, get_relup_code_paths(added, changed, removed, output_dir)},
                  :silent,
                  :no_warn_sasl
                ]
              )

            case result do
              {:ok, relup, _mod, []} ->
                Logger.info("Relup successfully created")
                Utils.write_term(Path.join(rel_dir, "relup"), relup)

              {:ok, relup, mod, warnings} ->
                Logger.warn(Utils.format_systools_warning(mod, warnings))
                Logger.info("Relup successfully created")
                Utils.write_term(Path.join(rel_dir, "relup"), relup)

              {:error, mod, errors} ->
                error = Utils.format_systools_error(mod, errors)
                {:error, {:assembler, error}}
            end
        end
    end
    |> IO.inspect(label: "generating relup")
  end

  # Get a list of applications from the .rel file at the given path
  @spec extract_relfile_apps(String.t()) :: [{atom, charlist}] | no_return
  defp extract_relfile_apps(path) when is_binary(path) do
    case Utils.read_terms(path) do
      {:error, _} = err ->
        throw(err)

      {:ok, [{:release, _rel, _erts, apps}]} ->
        Enum.map(apps, fn
          {a, v} -> {a, v}
          {a, v, _start_type} -> {a, v}
        end)

      {:ok, other} ->
        throw({:error, {:assembler, {:malformed_relfile, path, other}}})
    end
  end

  # Determine the set of apps which have changed between two versions
  defp get_changed_apps(a, b) do
    as = Enum.map(a, fn app -> elem(app, 0) end) |> MapSet.new()
    bs = Enum.map(b, fn app -> elem(app, 0) end) |> MapSet.new()
    shared = MapSet.to_list(MapSet.intersection(as, bs))
    a_versions = Enum.map(shared, fn n -> {n, elem(List.keyfind(a, n, 0), 1)} end) |> MapSet.new()
    b_versions = Enum.map(shared, fn n -> {n, elem(List.keyfind(b, n, 0), 1)} end) |> MapSet.new()

    MapSet.difference(b_versions, a_versions)
    |> MapSet.to_list()
    |> Enum.map(fn {n, v2} ->
      v1 = List.keyfind(a, n, 0) |> elem(1)
      {n, "#{v1}", "#{v2}"}
    end)
  end

  # Determine the set of apps which were added between two versions
  defp get_added_apps(v2_apps, changed) do
    changed_apps = Enum.map(changed, &elem(&1, 0))

    Enum.reject(v2_apps, fn a ->
      elem(a, 0) in changed_apps
    end)
  end

  # Determine the set of apps removed from v1 to v2
  defp get_removed_apps(a, b) do
    as = Enum.map(a, fn app -> elem(app, 0) end) |> MapSet.new()
    bs = Enum.map(b, fn app -> elem(app, 0) end) |> MapSet.new()

    MapSet.difference(as, bs)
    |> MapSet.to_list()
    |> Enum.map(fn n -> {n, elem(List.keyfind(a, n, 0), 1)} end)
  end

  # Generate .appup files for a list of {app, v1, v2}
  defp generate_appups(_rel, [], _output_dir), do: :ok

  defp generate_appups(release, [{app, v1, v2} | apps], output_dir) do
    v1_path = Path.join([output_dir, "lib", "#{app}-#{v1}"])
    v2_path = Path.join([output_dir, "lib", "#{app}-#{v2}"])
    target_appup_path = Path.join([v2_path, "ebin", "#{app}.appup"])

    appup_path =
      case Appup.locate(app, v1, v2) do
        nil ->
          target_appup_path

        path ->
          File.cp!(path, target_appup_path)
      end

    # Check for existence
    IO.inspect(target_appup_path, label: "target_appup_path")
    appup_exists? = File.exists?(target_appup_path)

    appup_valid? =
      if appup_exists? do
        case Utils.read_terms(target_appup_path) do
          {:ok, [{v2p, [{v1p, _}], [{v1p, _}]}]} ->
            cond do
              is_binary(v2p) and is_binary(v1p) ->
                # Versions are regular expressions
                v1p = Regex.compile!(v1p)
                v2p = Regex.compile!(v2p)
                String.match?(v1, v1p) and String.match?(v2, v2p)

              v2p == ~c[#{v2}] and v1p == ~c[#{v1}] ->
                true

              :else ->
                false
            end

          _other ->
            false
        end
      else
        false
      end

    cond do
      appup_exists? && appup_valid? ->
        Logger.debug("#{app} requires an appup, and one was provided, skipping generation..")
        generate_appups(release, apps, output_dir)

      appup_exists? ->
        Logger.warn(
          "#{app} has an appup file, but it is invalid for this release,\n" <>
            "    Backing up appfile with .bak extension and generating new one.."
        )

        :ok = File.cp!(target_appup_path, "#{appup_path}.bak")

        case Appup.make(app, v1, v2, v1_path, v2_path, release.profile.appup_transforms) do
          {:error, _} = err ->
            err

          {:ok, appup} ->
            :ok = Utils.write_term(target_appup_path, appup)
            Logger.info("Generated .appup for #{app} #{v1} -> #{v2}")
            generate_appups(release, apps, output_dir)
        end

      :else ->
        Logger.debug(
          "#{app} requires an appup, but it wasn't provided, one will be generated for you.."
        )

        IO.inspect(app, label: "app")
        IO.inspect(v1, label: "v1")
        IO.inspect(v2, label: "v2")
        IO.inspect(v1_path, label: "v1_path")
        IO.inspect(v2_path, label: "v2_path")
        IO.inspect(release.profile.appup_transforms, label: "release.profile.appup_transforms")
        case Appup.make(app, v1, v2, v1_path, v2_path, release.profile.appup_transforms) do
          {:error, _} = err ->
            IO.inspect(err, label: "error during gen appups")
            err

          {:ok, appup} ->
            :ok = Utils.write_term(target_appup_path, appup)
            Logger.info("Generated .appup for #{app} #{v1} -> #{v2}")
            generate_appups(release, apps, output_dir)
        end
    end
    |> IO.inspect(label: "after gen appups")
  end

  # Get a list of code paths containing only those paths which have beams
  # from the two versions in the release being upgraded
  defp get_relup_code_paths(added, changed, removed, output_dir) do
    added_paths = get_added_relup_code_paths(added, output_dir, [])
    changed_paths = get_changed_relup_code_paths(changed, output_dir, [], [])
    removed_paths = get_removed_relup_code_paths(removed, output_dir, [])
    added_paths ++ changed_paths ++ removed_paths
  end

  defp get_changed_relup_code_paths([], _output_dir, v1_paths, v2_paths) do
    v2_paths ++ v1_paths
  end

  defp get_changed_relup_code_paths([{app, v1, v2} | apps], output_dir, v1_paths, v2_paths) do
    v1_path = Path.join([output_dir, "lib", "#{app}-#{v1}", "ebin"]) |> String.to_charlist()
    v2_path = Path.join([output_dir, "lib", "#{app}-#{v2}", "ebin"]) |> String.to_charlist()

    v2_path_consolidated =
      Path.join([output_dir, "lib", "#{app}-#{v2}", "consolidated"]) |> String.to_charlist()

    get_changed_relup_code_paths(apps, output_dir, [v1_path | v1_paths], [
      v2_path_consolidated,
      v2_path | v2_paths
    ])
  end

  defp get_added_relup_code_paths([], _output_dir, paths), do: paths

  defp get_added_relup_code_paths([{app, v2} | apps], output_dir, paths) do
    v2_path = Path.join([output_dir, "lib", "#{app}-#{v2}", "ebin"]) |> String.to_charlist()

    v2_path_consolidated =
      Path.join([output_dir, "lib", "#{app}-#{v2}", "consolidated"]) |> String.to_charlist()

    get_added_relup_code_paths(apps, output_dir, [v2_path_consolidated, v2_path | paths])
  end

  defp get_removed_relup_code_paths([], _output_dir, paths), do: paths

  defp get_removed_relup_code_paths([{app, v1} | apps], output_dir, paths) do
    v1_path = Path.join([output_dir, "lib", "#{app}-#{v1}", "ebin"]) |> String.to_charlist()

    v1_path_consolidated =
      Path.join([output_dir, "lib", "#{app}-#{v1}", "consolidated"]) |> String.to_charlist()

    get_removed_relup_code_paths(apps, output_dir, [v1_path_consolidated, v1_path | paths])
  end

  defp make_paths(%Release{} = release) do
    rel_dir = Release.version_path(release)
    bin_dir = Release.bin_path(release)
    lib_dir = Release.lib_path(release)

    with {_, :ok} <- {rel_dir, File.mkdir_p(rel_dir)},
         {_, :ok} <- {lib_dir, File.mkdir_p(lib_dir)},
         {_, :ok} <- {bin_dir, File.mkdir_p(bin_dir)} do
      :ok
    else
      {path, {:error, reason}} ->
        {:error, {:assembler, :file, {reason, path}}}
    end
  end

  # cherry picking from other modules

  # @doc """
  # Get the path to which versioned release data will be output
  # """
  # def release_version_path(%{profile: %{output_dir: output_dir}} = r) do
  #   [output_dir, "releases", "#{r.version}"]
  #   |> Path.join()
  #   |> Path.expand()
  # end

  # defp apply_upgrade_configuration(%__MODULE__{} = release, %Config{upgrade_from: :latest}, log?) do
  #   current_version = release.version

  #   upfrom =
  #     case Utils.get_release_versions(release.profile.output_dir) do
  #       [] ->
  #         :no_upfrom

  #       [^current_version, v | _] ->
  #         v

  #       [v | _] ->
  #         v
  #     end

  #   case upfrom do
  #     :no_upfrom ->
  #       if log? do
  #         Shell.warn(
  #           "An upgrade was requested, but there are no " <>
  #             "releases to upgrade from, no upgrade will be performed."
  #         )
  #       end

  #       {:ok, %{release | :is_upgrade => false, :upgrade_from => nil}}

  #     v ->
  #       {:ok, %{release | :is_upgrade => true, :upgrade_from => v}}
  #   end
  # end
end
