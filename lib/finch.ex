defmodule Finch do
  @moduledoc """
  An HTTP client with a focus on performance.

  ## Usage

  In order to use Finch, you must start it and provide a `:name`. Often in your
  supervision tree:

  ```elixir
  children = [
    {Finch, name: MyFinch}
  ]
  ```

  Or, in rare cases, dynamically:

  ```elixir
  Finch.start_link(name: MyFinch)
  ```

  Once you have started Finch, you can use the client you have started,
  by passing the name of your client as the first argument of `Finch.request/3,4,5`:

  ```elixir
  Finch.request(MyFinch, :get, "https://hex.pm")
  ```

  When using HTTP/1, Finch will parse the passed in URL into a `{scheme, host, port}`
  tuple, and maintain one or more connection pools for each `{scheme, host, port}` you
  interact with.

  You can also configure a pool size and count to be used for specific URLs that are
  known before starting Finch. The passed URLs will be parsed into `{scheme, host, port}`,
  and the corresponding pools will be started. See `Finch.start_link/1` for configuration
  options.

  ```elixir
  children = [
    {Finch,
     name: MyConfiguredFinch,
     pools: %{
       :default => [size: 10],
       "https://hex.pm" => [size: 32, count: 8]
     }}
  ]
  ```

  Pools will be started for each configured `{scheme, host, port}` when Finch is started.
  For any unconfigured `{scheme, host, port}`, the pool will be started the first time
  it is requested. Note pools are not automatically terminated if they are unused, so
  Finch is best suited when you are requesting a known list of static hosts.

  ## Telemetry

  Finch uses Telemetry to provide instrumentation. See the `Finch.Telemetry`
  module for details on specific events.
  """

  alias Finch.{Pool, PoolManager}

  use Supervisor

  @atom_methods [
    :get,
    :post,
    :put,
    :patch,
    :delete,
    :head,
    :options
  ]
  @methods [
    "GET",
    "POST",
    "PUT",
    "PATCH",
    "DELETE",
    "HEAD",
    "OPTIONS"
  ]
  @atom_to_method Enum.zip(@atom_methods, @methods) |> Enum.into(%{})
  @default_pool_size 10
  @default_pool_count 1

  @pool_config_schema [
    size: [
      type: :pos_integer,
      doc: "Number of connections to maintain in each pool.",
      default: @default_pool_size
    ],
    count: [
      type: :pos_integer,
      doc: "Number of pools to start.",
      default: @default_pool_count
    ],
    conn_opts: [
      type: :keyword_list,
      doc:
        "These options are passed to `Mint.HTTP.connect/4` whenever a new connection is established. `:mode` is not configurable as Finch must control this setting. Typically these options are used to configure proxying, https settings, or connect timeouts.",
      default: []
    ]
  ]

  @doc """
  Start an instance of Finch.

  ## Options:
    * `:name` - The name of your Finch instance. This field is required.

    * `:pools` - A map specifying the configuration for your pools. The keys should be URLs 
    provided as binaries, or the atom `:default` to provide a catch-all configuration to be used
    for any unspecified URLs. See "Pool Configuration Options" below for details on the possible
    map values. Default value is `%{default: [size: #{@default_pool_size}, count: #{
    @default_pool_count
  }]}`.

  ### Pool Configuration Options
  #{NimbleOptions.docs(@pool_config_schema)}
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name) || raise ArgumentError, "must supply a name"
    pools = Keyword.get(opts, :pools, []) |> pool_options!()
    {default_pool_config, pools} = Map.pop(pools, :default)

    config = %{
      registry_name: name,
      manager_name: manager_name(name),
      supervisor_name: pool_supervisor_name(name),
      default_pool_config: default_pool_config,
      pools: pools
    }

    Supervisor.start_link(__MODULE__, config, name: supervisor_name(name))
  end

  @impl true
  def init(config) do
    children = [
      {DynamicSupervisor, name: config.supervisor_name, strategy: :one_for_one},
      {Registry, [keys: :duplicate, name: config.registry_name, meta: [config: config]]},
      {PoolManager, config}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def request(name, method, url, headers \\ [], body \\ nil, opts \\ []) do
    with {:ok, uri} <- parse_and_normalize_url(url) do
      req = %{
        scheme: uri.scheme,
        host: uri.host,
        port: uri.port,
        method: build_method(method),
        path: uri.path,
        headers: headers,
        body: body,
        query: uri.query
      }

      shp = {uri.scheme, uri.host, uri.port}

      pool = PoolManager.get_pool(name, shp)
      Pool.request(pool, req, opts)
    end
  end

  defp parse_and_normalize_url(url) when is_binary(url) do
    with parsed_uri <- URI.parse(url),
         normalized_path <- parsed_uri.path || "/",
         {:ok, scheme} <- normalize_scheme(parsed_uri.scheme) do
      normalized_uri = %{
        scheme: scheme,
        host: parsed_uri.host,
        port: parsed_uri.port,
        path: normalized_path,
        query: parsed_uri.query
      }

      {:ok, normalized_uri}
    end
  end

  defp build_method(method) when method in @methods, do: method

  defp build_method(method) when is_atom(method) do
    @atom_to_method[method]
  end

  defp normalize_scheme(scheme) do
    case scheme do
      "https" ->
        {:ok, :https}

      "http" ->
        {:ok, :http}

      scheme ->
        {:error, "invalid scheme #{inspect(scheme)}"}
    end
  end

  defp pool_options!(pools) do
    {:ok, default} = NimbleOptions.validate([], @pool_config_schema)

    Enum.reduce(pools, %{default: valid_opts_to_map(default)}, fn {destination, opts}, acc ->
      with {:ok, valid_destination} <- cast_destination(destination),
           {:ok, valid_pool_opts} <- cast_pool_opts(opts) do
        Map.put(acc, valid_destination, valid_pool_opts)
      else
        {:error, reason} ->
          raise ArgumentError, "got invalid configuration for pool #{destination}! #{reason}"
      end
    end)
  end

  defp cast_destination(destination) do
    case destination do
      :default ->
        {:ok, destination}

      url when is_binary(url) ->
        cast_binary_destination(url)

      _ ->
        {:error, "invalid destination"}
    end
  end

  defp cast_binary_destination(url) when is_binary(url) do
    with {:ok, uri} <- parse_and_normalize_url(url),
         shp <- {uri.scheme, uri.host, uri.port} do
      {:ok, shp}
    end
  end

  defp cast_pool_opts(opts) do
    with {:ok, valid} <- NimbleOptions.validate(opts, @pool_config_schema) do
      {:ok, valid_opts_to_map(valid)}
    end
  end

  defp valid_opts_to_map(valid) do
    %{
      size: valid[:size],
      count: valid[:count],
      conn_opts: valid[:conn_opts]
    }
  end

  defp supervisor_name(name), do: :"#{name}.Supervisor"
  defp manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"
end
