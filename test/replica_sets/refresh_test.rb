$:.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require './test/replica_sets/rs_test_helper'
require 'benchmark'

class ReplicaSetRefreshTest < Test::Unit::TestCase
  include ReplicaSetTest

  def setup
    @conn = nil
  end

  def teardown
    self.rs.restart_killed_nodes
    @conn.close if @conn
  end

  def test_connect_speed
    Benchmark.bm do |x|
      x.report("Connect") do
        10.times do
          ReplSetConnection.new([self.rs.host, self.rs.ports[0]], [self.rs.host, self.rs.ports[1]],
            [self.rs.host, self.rs.ports[2]], :refresh_mode => false)
        end
      end

          @con = ReplSetConnection.new([self.rs.host, self.rs.ports[0]], [self.rs.host, self.rs.ports[1]],
            [self.rs.host, self.rs.ports[2]], :refresh_mode => false)

      x.report("manager") do
        man = Mongo::PoolManager.new(@con, @con.seeds)
        10.times do
          man.connect
        end
      end
    end
  end

  def test_connect_and_manual_refresh_with_secondaries_down
    self.rs.kill_all_secondaries

    rescue_connection_failure do
      @conn = ReplSetConnection.new([self.rs.host, self.rs.ports[0]], [self.rs.host, self.rs.ports[1]],
        [self.rs.host, self.rs.ports[2]], :refresh_mode => false)
    end

    assert_equal [], @conn.secondaries
    assert @conn.connected?
    assert_equal @conn.read_pool, @conn.primary_pool

    # Refresh with no change to set
    @conn.refresh
    assert_equal [], @conn.secondaries
    assert @conn.connected?
    assert_equal @conn.read_pool, @conn.primary_pool

    self.rs.restart_killed_nodes
    assert_equal [], @conn.secondaries
    assert @conn.connected?
    assert_equal @conn.read_pool, @conn.primary_pool

    # Refresh with everything up
    @conn.refresh
    assert @conn.read_pool
    assert @conn.secondaries.length > 0
  end

  def test_automated_refresh_with_secondaries_down
    self.rs.kill_all_secondaries

    rescue_connection_failure do
      @conn = ReplSetConnection.new([self.rs.host, self.rs.ports[0]], [self.rs.host, self.rs.ports[1]],
        [self.rs.host, self.rs.ports[2]], :refresh_interval => 2, :refresh_mode => :async)
    end

    assert_equal [], @conn.secondaries
    assert @conn.connected?
    assert_equal @conn.read_pool, @conn.primary_pool

    self.rs.restart_killed_nodes
    sleep(4)

    assert @conn.read_pool != @conn.primary_pool, "Read pool and primary pool are identical."
    assert @conn.secondaries.length > 0, "No secondaries have been added."
  end

  def test_automated_refresh_with_removed_node
    @conn = ReplSetConnection.new([self.rs.host, self.rs.ports[0]], [self.rs.host, self.rs.ports[1]],
      [self.rs.host, self.rs.ports[2]], :refresh_interval => 2, :refresh_mode => :async)

    @conn.secondary_pools
    assert_equal 2, @conn.secondary_pools.length
    assert_equal 2, @conn.secondaries.length

    n = self.rs.remove_secondary_node
    sleep(4)

    assert_equal 1, @conn.secondaries.length
    assert_equal 1, @conn.secondary_pools.length

    self.rs.add_node(n)
  end

  def test_adding_and_removing_nodes
    @conn = ReplSetConnection.new([self.rs.host, self.rs.ports[0]],
                                  [self.rs.host, self.rs.ports[1]],
                                  [self.rs.host, self.rs.ports[2]],
                                  :refresh_interval => 2, :refresh_mode => :async)

    self.rs.add_node
    sleep(4)

    @conn2 = ReplSetConnection.new([self.rs.host, self.rs.ports[0]],
                                   [self.rs.host, self.rs.ports[1]],
                                   [self.rs.host, self.rs.ports[2]],
                                   :refresh_interval => 2, :refresh_mode => :async)

    assert @conn2.secondaries == @conn.secondaries
    assert_equal 3, @conn.secondary_pools.length
    assert_equal 3, @conn.secondaries.length

    config = @conn['admin'].command({:ismaster => 1})

    self.rs.remove_secondary_node
    sleep(4)
    config = @conn['admin'].command({:ismaster => 1})

    assert_equal 2, @conn.secondary_pools.length
    assert_equal 2, @conn.secondaries.length
  end
end
