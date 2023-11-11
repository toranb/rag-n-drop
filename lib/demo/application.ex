defmodule Demo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DemoWeb.Telemetry,
      {Nx.Serving, serving: serving(), name: SentenceTransformer},
      Demo.Repo,
      {DNSCluster, query: Application.get_env(:demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Demo.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Demo.Finch},
      # Start a worker by calling: Demo.Worker.start_link(arg)
      # {Demo.Worker, arg},
      # Start to serve requests, typically the last entry
      DemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Demo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  def serving() do
    repo = "BAAI/bge-small-en-v1.5"
    {:ok, model_info} = Bumblebee.load_model({:hf, repo})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, repo})

    Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
      output_pool: :mean_pooling,
      output_attribute: :hidden_state,
      embedding_processor: :l2_norm,
      compile: [batch_size: 32, sequence_length: [32]],
      defn_options: [compiler: EXLA]
    )
  end
end
