defmodule Nebulex.Adapters.ReplicatedTest do
  use Nebulex.NodeCase
  use Mimic

  # Inherit tests
  use Nebulex.CacheTest

  import Nebulex.Helpers

  alias Nebulex.TestCache.{Replicated, ReplicatedMock}

  @cache_name :replicated_cache

  setup do
    node_pid_list = start_caches(cluster_nodes(), [{Replicated, [name: @cache_name]}])

    default_dynamic_cache = Replicated.get_dynamic_cache()
    _ = Replicated.put_dynamic_cache(@cache_name)

    on_exit(fn ->
      _ = Replicated.put_dynamic_cache(default_dynamic_cache)

      :ok = Process.sleep(100)

      stop_caches(node_pid_list)
    end)

    {:ok, cache: Replicated, name: @cache_name}
  end

  describe "c:init/1" do
    test "raises an exception because invalid primary store" do
      assert_raise ArgumentError, ~r"adapter Invalid was not compiled", fn ->
        defmodule Demo do
          use Nebulex.Cache,
            otp_app: :nebulex,
            adapter: Nebulex.Adapters.Replicated,
            primary_storage_adapter: Invalid
        end
      end
    end
  end

  describe "replicated cache:" do
    test "put/3" do
      assert Replicated.put(1, 1) == :ok
      assert Replicated.get!(1) == 1

      assert_for_all_replicas(Replicated, :get!, [1], 1)

      assert Replicated.put_all(a: 1, b: 2, c: 3) == :ok

      assert_for_all_replicas(Replicated, :get_all!, [[:a, :b, :c]], %{a: 1, b: 2, c: 3})
    end

    test "delete/2" do
      assert Replicated.put("foo", "bar") == :ok
      assert Replicated.get!("foo") == "bar"

      assert_for_all_replicas(Replicated, :get!, ["foo"], "bar")

      assert Replicated.delete("foo") == :ok
      refute Replicated.get!("foo")

      assert_for_all_replicas(Replicated, :get!, ["foo"], nil)
    end

    test "take/2" do
      assert Replicated.put("foo", "bar") == :ok
      assert Replicated.get!("foo") == "bar"

      assert_for_all_replicas(Replicated, :get!, ["foo"], "bar")

      assert Replicated.take!("foo") == "bar"
      refute Replicated.get!("foo")

      assert_for_all_replicas(Replicated, :get!, ["foo"], nil)
    end

    test "take/2 (Nebulex.KeyError on remote nodes)" do
      Replicated.__primary__().with_dynamic_cache(
        normalize_module_name([@cache_name, Primary]),
        fn ->
          :ok = Replicated.__primary__().put("foo", "bar")
        end
      )

      assert Replicated.take!("foo") == "bar"
      refute Replicated.get!("foo")

      assert_for_all_replicas(Replicated, :get!, ["foo"], nil)
    end

    test "incr/3" do
      assert Replicated.incr!(:counter, 3) == 3
      assert Replicated.incr!(:counter) == 4

      assert_for_all_replicas(Replicated, :get!, [:counter], 4)
    end

    test "incr/3 raises when the counter is not an integer" do
      :ok = Replicated.put(:counter, "string")

      assert_raise ArgumentError, fn ->
        Replicated.incr(:counter, 10)
      end
    end

    test "delete_all/2" do
      assert Replicated.put_all(a: 1, b: 2, c: 3) == :ok

      assert_for_all_replicas(Replicated, :get_all!, [[:a, :b, :c]], %{a: 1, b: 2, c: 3})

      assert Replicated.delete_all!() == 3
      assert Replicated.count_all!() == 0

      assert_for_all_replicas(Replicated, :get_all!, [[:a, :b, :c]], %{})
    end
  end

  describe "cluster" do
    test "node leaves and then rejoins", %{name: name} do
      cluster = :lists.usort(cluster_nodes())

      wait_until(fn ->
        assert Replicated.nodes() == cluster
      end)

      Replicated.with_dynamic_cache(name, fn ->
        :ok = Replicated.leave_cluster()
      end)

      wait_until(fn ->
        assert Replicated.nodes() == cluster -- [node()]
      end)

      Replicated.with_dynamic_cache(name, fn ->
        :ok = Replicated.join_cluster()
      end)

      wait_until(fn ->
        assert Replicated.nodes() == cluster
      end)
    end

    test "error: rpc error" do
      node_pid_list = start_caches(cluster_nodes(), [{ReplicatedMock, []}])

      try do
        _ = Process.flag(:trap_exit, true)

        assert {:error, %Nebulex.Error{reason: {:rpc_multicall_error, errors}}} =
                 ReplicatedMock.put_new_all(a: 1, b: 2)

        for {_node, error} <- errors do
          assert error == {:exit, {:signal, :normal}}
        end
      after
        stop_caches(node_pid_list)
      end
    end

    test "ok: start/stop cache nodes" do
      event = [:nebulex, :test_cache, :replicated, :replication]

      with_telemetry_handler(__MODULE__, [event], fn ->
        assert Replicated.nodes() |> :lists.usort() == :lists.usort(cluster_nodes())

        assert Replicated.put_all(a: 1, b: 2) == :ok
        assert Replicated.put(:c, 3, ttl: 5000) == :ok

        assert_for_all_replicas(
          Replicated,
          :get_all!,
          [[:a, :b, :c]],
          %{a: 1, b: 2, c: 3}
        )

        # start new cache nodes
        nodes = [:"node3@127.0.0.1", :"node4@127.0.0.1"]
        node_pid_list = start_caches(nodes, [{Replicated, [name: @cache_name]}])

        wait_until(fn ->
          assert Replicated.nodes() |> :lists.usort() == :lists.usort(nodes ++ cluster_nodes())
        end)

        wait_until(10, 1000, fn ->
          assert_for_all_replicas(
            Replicated,
            :get_all!,
            [[:a, :b, :c]],
            %{a: 1, b: 2, c: 3}
          )
        end)

        # stop cache node
        :ok = node_pid_list |> hd() |> List.wrap() |> stop_caches()

        if Code.ensure_loaded?(:pg) do
          # errors on failed nodes should be ignored
          Nebulex.Cache.Cluster
          |> expect(:get_nodes, fn _ -> [:"node5@127.0.0.1"] ++ nodes end)

          assert Replicated.put(:foo, :bar) == :ok

          assert_receive {^event, %{rpc_errors: 2}, meta}
          assert meta[:adapter_meta][:cache] == Replicated
          assert meta[:adapter_meta][:name] == :replicated_cache
          assert meta[:function_name] == :put

          assert [
                   "node5@127.0.0.1": {:error, {:erpc, :noconnection}},
                   "node3@127.0.0.1": {:error, %Nebulex.Error{reason: {:registry_error, _}}}
                 ] = meta[:rpc_errors]
        end

        wait_until(10, 1000, fn ->
          assert Replicated.nodes() |> :lists.usort() ==
                   :lists.usort(cluster_nodes() ++ [:"node4@127.0.0.1"])
        end)

        assert_for_all_replicas(
          Replicated,
          :get_all!,
          [[:a, :b, :c]],
          %{a: 1, b: 2, c: 3}
        )

        :ok = stop_caches(node_pid_list)
      end)
    end
  end

  describe "write-like operations locked" do
    test "when a delete_all command is ongoing" do
      test_with_dynamic_cache(ReplicatedMock, [name: :replicated_global_mock], fn ->
        true = Process.register(self(), __MODULE__)
        _ = Process.flag(:trap_exit, true)

        task1 =
          Task.async(fn ->
            _ = ReplicatedMock.put_dynamic_cache(:replicated_global_mock)
            _ = ReplicatedMock.delete_all()
            send(__MODULE__, :delete_all)
          end)

        task2 =
          Task.async(fn ->
            :ok = Process.sleep(1000)
            _ = ReplicatedMock.put_dynamic_cache(:replicated_global_mock)
            :ok = ReplicatedMock.put("foo", "bar")
            :ok = Process.sleep(100)
            send(__MODULE__, :put)
          end)

        assert_receive :delete_all, 5000
        assert_receive :put, 5000

        [_, _] = Task.yield_many([task1, task2])
      end)
    end
  end

  ## Helpers

  defp assert_for_all_replicas(cache, action, args, expected) do
    assert {res_lst, []} =
             :rpc.multicall(
               cache.nodes(),
               cache,
               :with_dynamic_cache,
               [@cache_name, cache, action, args]
             )

    Enum.each(res_lst, fn res -> assert res == expected end)
  end

  defp cluster_nodes do
    [node() | Node.list()] -- [:"node3@127.0.0.1", :"node4@127.0.0.1"]
  end
end
