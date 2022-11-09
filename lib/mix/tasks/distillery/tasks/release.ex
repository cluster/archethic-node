defmodule Mix.Tasks.Distillery.Release do
  @moduledoc """
  Build a release for the current mix application.

  ## Command line options

    * `--name`    - selects a specific release to build
    * `--env`     - selects a specific release environment to build with
    * `--profile` - selects both a release and environment, syntax for profiles is `name:env`

  Releases and environments are defined in `rel/config.exs`, created via
  `distillery.init`. When determining the name and environment to use, refer to the
  definitions in that file if you are not sure what options are available.

    * `--erl`     - provide extra flags to `erl` when running the release, expects a string
    * `--dev`     - this switch indicates whether to build the release in "dev mode", which
      symlinks build artifacts into the release rather than copying them, both significantly
      speeding up release builds, as well as making it possible to recompile the project and
      have the release pick up the changes without rebuilding the release.
    * `--silent`  - mutes all logging output
    * `--quiet`   - reduce logging output to essentials
    * `--verbose` - produce detailed output about release assembly
    * `--no-tar`  - skip packaging the release in a tarball after assembly
    * `--warnings-as-errors` - treat any release-time warnings as errors which fail the build
    * `--no-warn-missing`    - ignore any errors about missing applications

  ### Upgrades

  You can tell Distillery to build an upgrade with `--upgrade`.

  Upgrades require a source version and a target version (the current version).
  Distillery will automatically determine a source version by looking at previously
  built releases in the output directory, and selecting the most recent. If none
  are available, building the upgrade will fail. You can specify a specific version
  to upgrade from with `--upfrom`, which expects a version string. If the selected
  version cannot be found, the upgrade build will fail.

  ### Executables

  Distillery can build pseudo-executable files as an artifact, rather than plain
  tarballs. These executables are not true executables, but rather self-extracting
  TAR archives, which handle extraction and passing any command-line arguments to
  the appropriate shell scripts in the release. The following flags are used for
  these executables:

    * `--executable`  - tells Distillery to produce a self-extracting archive
    * `--transient`   - tells Distillery to produce a self-extracting archive which
      will remove the extracted contents from disk after execution

  ## Usage

  You are generally recommended to use `rel/config.exs` to configure Distillery, and
  simply run `mix distillery.release` with `MIX_ENV` set to the Mix environment you are targeting.
  The following are some usage examples:

      # Builds a release with MIX_ENV=dev (the default)
      mix distillery.release

      # Builds a release with MIX_ENV=prod
      MIX_ENV=prod mix distillery.release

      # Builds a release for a specific release environment
      MIX_ENV=prod mix distillery.release --env=dev

  The default configuration produced by `distillery.init` will result in `mix distillery.release`
  selecting the first release in the config file (`rel/config.exs`), and the
  environment which matches the current Mix environment (i.e. the value of `MIX_ENV`).
  """

  require Logger

  @doc false
  @spec parse_args(OptionParser.argv()) :: Keyword.t() | no_return
  @spec parse_args(OptionParser.argv(), Keyword.t()) :: Keyword.t() | no_return
  def parse_args(argv, opts \\ []) do
    switches = [
      silent: :boolean,
      quiet: :boolean,
      verbose: :boolean,
      executable: :boolean,
      transient: :boolean,
      dev: :boolean,
      erl: :string,
      run_erl_env: :string,
      no_tar: :boolean,
      upgrade: :boolean,
      upfrom: :string,
      name: :string,
      profile: :string,
      env: :string,
      no_warn_missing: :boolean,
      warnings_as_errors: :boolean
    ]

    flags =
      if Keyword.get(opts, :strict, true) do
        {flags, _} = OptionParser.parse!(argv, strict: switches)
        flags
      else
        {flags, _, _} = OptionParser.parse(argv, strict: switches)
        flags
      end

    defaults = %{
      verbosity: :normal,
      selected_release: :default,
      selected_environment: :default,
      executable: [enabled: false, transient: false],
      is_upgrade: false,
      no_tar: false,
      upgrade_from: :latest,
      erl_opts: nil
    }

    do_parse_args(flags, defaults)
  end

  defp do_parse_args([], acc), do: Map.to_list(acc)

  defp do_parse_args([{:verbose, _} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :verbosity, :verbose))
  end

  defp do_parse_args([{:quiet, _} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :verbosity, :quiet))
  end

  defp do_parse_args([{:silent, _} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :verbosity, :silent))
  end

  defp do_parse_args([{:profile, profile} | rest], acc) do
    case String.split(profile, ":", trim: true, parts: 2) do
      [rel, env] ->
        new_acc =
          acc
          |> Map.put(:selected_release, String.to_atom(rel))
          |> Map.put(:selected_environment, String.to_atom(env))

        do_parse_args(rest, new_acc)

      other ->
        Logger.error("invalid profile name `#{other}`, must be `name:env`")
    end
  end

  defp do_parse_args([{:name, name} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :selected_release, String.to_atom(name)))
  end

  defp do_parse_args([{:env, name} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :selected_environment, String.to_atom(name)))
  end

  defp do_parse_args([{:no_warn_missing, _} | rest], acc) do
    Logger.warn("The --no-warn-missing flag has been deprecated, as it is no longer used")
    do_parse_args(rest, acc)
  end

  defp do_parse_args([{:no_tar, _} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :no_tar, true))
  end

  defp do_parse_args([{:executable, e} | _rest], %{is_upgrade: true}) when e != false do
    Logger.error("You cannot combine --executable with --upgrade")
  end

  defp do_parse_args([{:executable, val} | rest], acc) do
    case :os.type() do
      {:win32, _} when val == true ->
        Logger.error("--executable is not supported on Windows")

      _ ->
        case Map.get(acc, :executable) do
          nil ->
            do_parse_args(rest, Map.put(acc, :executable, enabled: val, transient: false))

          opts when is_list(opts) ->
            do_parse_args(rest, Map.put(acc, :executable, Keyword.put(opts, :enabled, val)))
        end
    end
  end

  defp do_parse_args([{:upgrade, _} | rest], %{executable: e} = acc) do
    if is_list(e) and Keyword.get(e, :enabled) == true do
      Logger.error("You cannot combine --executable with --upgrade")
    else
      do_parse_args(rest, Map.put(acc, :is_upgrade, true))
    end
  end

  defp do_parse_args([{:upgrade, _} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :is_upgrade, true))
  end

  defp do_parse_args([{:warnings_as_errors, _} | rest], acc) do
    Application.put_env(:distillery, :warnings_as_errors, true)
    do_parse_args(rest, acc)
  end

  defp do_parse_args([{:transient, val} | rest], acc) do
    executable =
      case Map.get(acc, :executable) do
        e when e in [nil, false] ->
          [enabled: false, transient: val]

        e when is_list(e) ->
          Keyword.put(e, :transient, val)
      end

    do_parse_args(rest, Map.put(acc, :executable, executable))
  end

  defp do_parse_args([{:upfrom, version} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :upgrade_from, version))
  end

  defp do_parse_args([{:erl, erl_opts} | rest], acc) do
    do_parse_args(rest, Map.put(acc, :erl_opts, erl_opts))
  end
end
