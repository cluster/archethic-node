defmodule Archethic.Contracts.Contract.Context do
  @moduledoc """
  A structure to pass around between nodes that contains details about the contract execution.
  """

  alias Archethic.Contracts.Contract

  @enforce_keys [:status, :trigger, :trigger_type, :timestamp]
  defstruct [
    :status,
    :trigger,
    :trigger_type,
    :timestamp
  ]

  @type status :: :no_output | :tx_output | :failure

  @typedoc """
  Think of trigger as an "instance" of a trigger_type
  """
  @type trigger ::
          {:transaction, Crypto.prepended_hash()}
          | {:oracle, Crypto.prepended_hash()}
          | {:datetime, DateTime.t()}
          | {:interval, String.t(), DateTime.t()}

  @type t :: %__MODULE__{
          status: status(),
          trigger: trigger(),
          timestamp: DateTime.t()
        }

  @spec serialize(t()) :: bitstring()
  def serialize(%__MODULE__{
        status: status,
        trigger: trigger,
        timestamp: timestamp
      }) do
    <<serialize_status(status)::8, DateTime.to_unix(timestamp, :millisecond)::64,
      serialize_trigger(trigger)::binary>>
  end

  @spec deserialize(bitstring()) :: {t(), bitstring()}
  def deserialize(<<rest::bitstring>>) do
    {status, <<timestamp::64, rest::binary>>} = deserialize_status(rest)

    {trigger, rest} = deserialize_trigger(rest)

    {%__MODULE__{
       status: status,
       trigger: trigger,
       timestamp: DateTime.from_unix!(timestamp, :millisecond)
     }, rest}
  end

  defp serialize_status(:no_output), do: 0
  defp serialize_status(:tx_output), do: 1
  defp serialize_status(:failure), do: 2

  defp deserialize_status(<<0::8, rest::binary>>), do: {:no_output, rest}
  defp deserialize_status(<<1::8, rest::binary>>), do: {:tx_output, rest}
  defp deserialize_status(<<2::8, rest::binary>>), do: {:failure, rest}

  ##
  defp serialize_trigger({:transaction, address}) do
    <<0::8, address::binary>>
  end

  defp serialize_trigger({:oracle, address}) do
    <<1::8, address::binary>>
  end

  defp serialize_trigger({:datetime, datetime}) do
    <<2::8, DateTime.to_unix(datetime, :millisecond)::64>>
  end

  defp serialize_trigger({:interval, cron, datetime}) do
    cron_size = byte_size(cron)
    <<3::8, cron_size::16, cron::binary, DateTime.to_unix(datetime, :millisecond)::64>>
  end

  ##
  defp deserialize_trigger(<<0::8, rest::binary>>) do
    {tx_address, rest} = Utils.deserialize_address(rest)
    {{:transaction, tx_address}, rest}
  end

  defp deserialize_trigger(<<1::8, rest::binary>>) do
    {tx_address, rest} = Utils.deserialize_address(rest)
    {{:oracle, tx_address}, rest}
  end

  defp deserialize_trigger(<<2::8, timestamp::64, rest::binary>>) do
    {{:datetime, DateTime.from_unix!(timestamp, :millisecond)}, rest}
  end

  defp deserialize_trigger(<<3::8, cron_size::16, rest::binary>>) do
    <<cron::binary-size(cron_size), timestamp::64, rest::binary>> = rest

    {{:interval, cron, DateTime.from_unix!(timestamp, :millisecond)}, rest}
  end
end
