defmodule Uniris.Mining.PendingTransactionValidationTest do
  use UnirisCase, async: false

  alias Uniris.Crypto

  alias Uniris.Governance.Pools.MemTable, as: PoolsMemTable

  alias Uniris.Mining.PendingTransactionValidation

  alias Uniris.P2P
  alias Uniris.P2P.Message.FirstPublicKey
  alias Uniris.P2P.Message.GetFirstPublicKey
  alias Uniris.P2P.Node

  alias Uniris.TransactionChain.Transaction
  alias Uniris.TransactionChain.TransactionData
  alias Uniris.TransactionChain.TransactionData.Keys

  import Mox

  setup do
    P2P.add_and_connect_node(%Node{
      first_public_key: Crypto.last_node_public_key(),
      network_patch: "AAA"
    })

    :ok
  end

  describe "validate_pending_transaction/1" do
    test "should :ok when a node transaction data content contains node endpoint information" do
      tx =
        Transaction.new(
          :node,
          %TransactionData{
            content: """
            ip: 127.0.0.1
            port: 3000
            transport: tcp
            reward address: 00A3EDE95D0EF1F10890DA69108AF3DF11B65709073592AE7D05F42A23D18E18A4
            """
          },
          "seed",
          0
        )

      assert :ok = PendingTransactionValidation.validate(tx)
    end

    test "should return :ok when a node shared secrets transaction data keys contains existing node public keys with first tx" do
      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node_key1",
        last_public_key: "node_key1",
        available?: true
      })

      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node_key2",
        last_public_key: "node_key2",
        available?: true
      })

      tx =
        Transaction.new(
          :node_shared_secrets,
          %TransactionData{
            content: """
            daily nonce public key: 00E05F60452CB68ACA06EC767109AD7B6730A286147A713C7AC724694F1C0C42D8
            network pool address: 004321DEBA4949B0EA9B0790177FEE2C735344B39CCBBAF4D812A4D76225F370FD
            """,
            code: """
            condition inherit: [
              type: node_shared_secrets
            ]
            """,
            keys: %Keys{
              secret: :crypto.strong_rand_bytes(32),
              authorized_keys: %{
                "node_key1" => "",
                "node_key2" => ""
              }
            }
          }
        )

      assert :ok = PendingTransactionValidation.validate(tx)
    end

    test "should return :ok when a code approval transaction contains a proposal target and the sender is member of the technical council and not previously signed" do
      tx =
        Transaction.new(
          :code_approval,
          %TransactionData{
            recipients: ["@CodeProposal1"]
          },
          "approval_seed",
          0
        )

      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node1",
        last_public_key: "node1",
        geo_patch: "AAA",
        network_patch: "AAA",
        available?: true,
        authorized?: true,
        authorization_date: DateTime.utc_now()
      })

      assert :ok = PoolsMemTable.put_pool_member(:technical_council, tx.previous_public_key)

      MockDB
      |> expect(:get_transaction, fn _, _ ->
        {:ok,
         %Transaction{
           data: %TransactionData{
             content: """
             Description: My Super Description
             Changes:
             diff --git a/mix.exs b/mix.exs
             index d9d9a06..5e34b89 100644
             --- a/mix.exs
             +++ b/mix.exs
             @@ -4,7 +4,7 @@ defmodule Uniris.MixProject do
               def project do
                 [
                   app: :uniris,
             -      version: \"0.7.1\",
             +      version: \"0.7.2\",
                   build_path: \"_build\",
                   config_path: \"config/config.exs\",
                   deps_path: \"deps\",
             @@ -53,7 +53,7 @@ defmodule Uniris.MixProject do
                   {:git_hooks, \"~> 0.4.0\", only: [:test, :dev], runtime: false},
                   {:mox, \"~> 0.5.2\", only: [:test]},
                   {:stream_data, \"~> 0.4.3\", only: [:test]},
             -      {:elixir_make, \"~> 0.6.0\", only: [:dev, :test], runtime: false},
             +      {:elixir_make, \"~> 0.6.0\", only: [:dev, :test]},
                   {:logger_file_backend, \"~> 0.0.11\", only: [:dev]}
                 ]
               end
             """
           }
         }}
      end)

      MockClient
      |> expect(:send_message, fn _, %GetFirstPublicKey{} ->
        {:ok, %FirstPublicKey{public_key: tx.previous_public_key}}
      end)

      assert :ok = PendingTransactionValidation.validate(tx)
    end

    test "should return :ok when a transaction contains a valid smart contract code" do
      tx_seed = :crypto.strong_rand_bytes(32)

      tx =
        Transaction.new(
          :transfer,
          %TransactionData{
            code: """
            condition inherit: [
              content: "hello"
            ]

            condition transaction: [
              content: ""
            ]

            actions triggered_by: transaction do
              set_content "hello"
            end
            """,
            keys:
              Keys.new(
                [Crypto.storage_nonce_public_key()],
                :crypto.strong_rand_bytes(32),
                tx_seed
              )
          },
          tx_seed,
          0
        )

      assert :ok = PendingTransactionValidation.validate(tx)
    end
  end
end
