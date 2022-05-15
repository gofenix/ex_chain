Mix.install(
  [:plug_cowboy, :poison, :elixir_uuid, :req],
  verbose: true
)

:ets.new(:buckets_registry, [:named_table, :public])

defmodule KV do
  def insert(bc) do
    :ets.insert(:buckets_registry, {"blockchain", bc})
  end

  def lookup() do
    :ets.lookup(:buckets_registry, "blockchain")
  end
end

defmodule Blockchain do
  defstruct chain: [], current_transactions: [], nodes: MapSet.new()

  def register_node(node) do
    {_, bc} = KV.lookup() |> hd()
    parse_url = URI.parse(node)
    bc = %{bc | nodes: bc.nodes |> MapSet.put("#{parse_url.host}:#{parse_url.port}")}
    KV.insert(bc)
  end

  def resolve_conflicts() do
    {_, bc} = KV.lookup() |> hd()

    new_chain =
      bc.nodes
      |> Enum.map(fn n ->
        IO.inspect(n)
        Req.get!("http://#{n}/chain").body |> Poison.decode!()
      end)
      |> Enum.sort_by(fn x -> -x["length"] end)
      |> Enum.filter(fn x -> true end)
      |> hd()

    if length(bc.chain) do
      bc = %{bc | chain: new_chain["chain"]}
      KV.insert(bc)
    else
      IO.inspect("not conflict")
    end
  end

  def valid_chain?() do

  end

  def new_block(bc, proof, previous_hash \\ nil) do
    block = %{
      :index => length(bc.chain) + 1,
      :timestamp => NaiveDateTime.utc_now(),
      :transactions => bc.current_transactions,
      :proof => proof,
      :previous_hash => previous_hash || bc |> last_block() |> hash()
    }

    bc = %{bc | chain: bc.chain ++ [block], current_transactions: []}
    bc |> KV.insert()

    block
  end

  def init() do
    bc = %Blockchain{
      chain: [],
      current_transactions: []
    }

    block = bc |> new_block(100, "")

    %{bc | chain: [block], current_transactions: []}
  end

  def new_transaction(bc, sender, recipient, amount) do
    tx = %{
      :sender => sender,
      :recipient => recipient,
      :amount => amount
    }

    bc = %{bc | current_transactions: bc.current_transactions ++ [tx]}
    bc |> KV.insert()
    bc
  end

  def last_block(bc) do
    bc.chain |> Enum.at(-1)
  end

  def hash(block) do
    value = block |> Poison.encode!()

    :crypto.hash(:sha256, value)
    |> Base.encode16()
    |> String.downcase()
  end

  def proof_of_work(last_proof, proof \\ 0) do
    if valid_proof?(last_proof, proof) do
      proof
    else
      proof_of_work(last_proof, proof + 1)
    end
  end

  def valid_proof?(last_proof, proof, difficulty \\ "000") do
    guess = "#{last_proof}#{proof}"

    guess_hash =
      :crypto.hash(:sha256, guess)
      |> Base.encode16()
      |> String.downcase()

    IO.write("\rdifficulty: #{difficulty}, attempt: #{proof}, hash: #{guess_hash}")
    guess_hash |> String.starts_with?(difficulty)
  end
end

bc = Blockchain.init()

defmodule Router do
  use Plug.Router
  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["text/*"],
    json_decoder: Poison
  )

  plug(:match)
  plug(:dispatch)

  @node_identifier UUID.uuid4()

  get "/" do
    send_resp(conn, 200, "Hello, World!")
  end

  get "/mine" do
    KV.lookup() |> IO.inspect()

    {_, bc} = KV.lookup() |> hd()

    last_block = bc |> Blockchain.last_block()
    last_proof = last_block[:proof]

    proof = Blockchain.proof_of_work(last_proof)

    previous_hash = last_block |> Blockchain.hash()

    block =
      bc
      |> Blockchain.new_transaction(
        "0",
        @node_identifier,
        1
      )
      |> Blockchain.new_block(proof, previous_hash)

    resp = %{
      :message => "New Block Forged",
      :block => block
    }

    send_resp(conn, 200, resp |> Poison.encode!())
  end

  get "/transactions/new" do
    {_, bc} = KV.lookup() |> hd()

    conn.query_string() |> IO.inspect()

    values = conn.query_string() |> String.split("&")

    sender = values |> Enum.at(0) |> String.split("=") |> Enum.at(1)
    recipient = values |> Enum.at(1) |> String.split("=") |> Enum.at(1)
    amount = values |> Enum.at(2) |> String.split("=") |> Enum.at(1)

    last_block =
      bc |> Blockchain.new_transaction(sender, recipient, amount) |> Blockchain.last_block()

    send_resp(conn, 200, "#{last_block.index + 1}")
  end

  get "/chain" do
    {_, bc} = KV.lookup() |> hd()

    resp = %{
      :chain => bc.chain,
      :length => length(bc.chain)
    }

    send_resp(conn, 200, resp |> Poison.encode!())
  end

  post "/nodes/register" do
    conn.body_params()["nodes"] |> Enum.each(fn x -> x |> Blockchain.register_node() end)

    {_, bc} = KV.lookup() |> hd()

    resp = %{
      :message => "New nodes have been added",
      :total_nodes => bc.nodes
    }

    send_resp(conn, 200, resp |> Poison.encode!())
  end

  get "/nodes/resolve" do
    Blockchain.resolve_conflicts()

    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

port = System.argv() |> hd() |> String.to_integer()
Blockchain.register_node("http://localhost:#{port}")

plug_cowboy = {Plug.Cowboy, plug: Router, scheme: :http, port: port}
require Logger
Logger.info("starting #{inspect(plug_cowboy)}")
{:ok, _} = Supervisor.start_link([plug_cowboy], strategy: :one_for_one)

Process.sleep(:infinity)
