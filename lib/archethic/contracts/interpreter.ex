defmodule Archethic.Contracts.Interpreter do
  @moduledoc false

  require Logger

  alias __MODULE__.Legacy
  alias __MODULE__.Version1

  alias Archethic.Contracts.Contract
  alias Archethic.Contracts.ContractConditions, as: Conditions

  alias Archethic.TransactionChain.Transaction

  @type version() :: integer()

  @doc """
  Dispatch through the correct interpreter.
  This return a filled contract structure or an human-readable error.
  """
  @spec parse(code :: binary()) :: {:ok, Contract.t()} | {:error, String.t()}
  def parse(code) when is_binary(code) do
    case sanitize_code(code) do
      {:ok, block} ->
        case block do
          {:__block__, [], [{:@, _, [{{:atom, "version"}, _, [version]}]} | rest]} ->
            Version1.parse({:__block__, [], rest}, version)

          _ ->
            Legacy.parse(block)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sanitize code takes care of converting atom to {:atom, bin()}.
  This way the user cannot create atoms at all. (which is mandatory to avoid atoms-table exhaustion)
  """
  @spec sanitize_code(binary()) :: {:ok, Macro.t()} | {:error, any()}
  def sanitize_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> Code.string_to_quoted(static_atoms_encoder: &atom_encoder/2)
  end

  @doc """
  Return true if the given conditions are valid on the given constants
  """
  @spec valid_conditions?(version(), Conditions.t(), map()) :: bool()
  def valid_conditions?(0, conditions, constants) do
    Legacy.valid_conditions?(conditions, constants)
  end

  def valid_conditions?(1, conditions, constants) do
    Version1.valid_conditions?(conditions, constants)
  end

  @doc """
  Execute the trigger/action code.
  May return a new transaction or nil
  """
  @spec execute_trigger(version(), Macro.t(), map()) :: Transaction.t() | nil
  def execute_trigger(0, ast, constants) do
    Legacy.execute_trigger(ast, constants)
  end

  def execute_trigger(1, ast, constants) do
    Version1.execute_trigger(ast, constants)
  end

  @doc """
  Format an error message from the failing ast node

  It returns message with metadata if possible to indicate the line of the error
  """
  @spec format_error_reason(any(), String.t()) :: String.t()
  def format_error_reason({:atom, _key}, reason) do
    do_format_error_reason(reason, "", [])
  end

  def format_error_reason({{:atom, key}, metadata, _}, reason) do
    do_format_error_reason(reason, key, metadata)
  end

  def format_error_reason({_, metadata, [{:__aliases__, _, [atom: module]} | _]}, reason) do
    do_format_error_reason(reason, module, metadata)
  end

  def format_error_reason(ast_node = {_, metadata, _}, reason) do
    node_msg =
      try do
        Macro.to_string(ast_node)
      rescue
        _ ->
          # {:atom, _} is not an atom so it breaks the Macro.to_string/1
          # here we replace it with :_var_
          {sanified_ast, variables} =
            Macro.traverse(
              ast_node,
              [],
              fn node, acc -> {node, acc} end,
              fn
                {:atom, bin}, acc -> {:_var_, [bin | acc]}
                node, acc -> {node, acc}
              end
            )

          # then we will replace all instances of _var_ in the string with the binary
          variables
          |> Enum.reverse()
          |> Enum.reduce(Macro.to_string(sanified_ast), fn variable, acc ->
            String.replace(acc, "_var_", variable, global: false)
          end)
      end

    do_format_error_reason(reason, node_msg, metadata)
  end

  def format_error_reason({{:atom, _}, {_, metadata, _}}, reason) do
    do_format_error_reason(reason, "", metadata)
  end

  def format_error_reason({{:atom, key}, _}, reason) do
    do_format_error_reason(reason, key, [])
  end

  defp do_format_error_reason(message, cause, metadata) do
    message = prepare_message(message)

    [prepare_message(message), cause, metadata_to_string(metadata)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" - ")
  end

  defp prepare_message(message) when is_atom(message) do
    message |> Atom.to_string() |> String.replace("_", " ")
  end

  defp prepare_message(message) when is_binary(message) do
    String.trim_trailing(message, ":")
  end

  defp metadata_to_string(line: line, column: column), do: "L#{line}:C#{column}"
  defp metadata_to_string(line: line), do: "L#{line}"
  defp metadata_to_string(_), do: ""

  defp atom_encoder(atom, _) do
    if atom in ["if"] do
      {:ok, String.to_atom(atom)}
    else
      {:ok, {:atom, atom}}
    end
  end
end
