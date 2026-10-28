require_relative 'test_helper'

class ActiveRecordReplicaTest < ReplicaTest
  def test_installation_and_query_paths_on_both_pools
    assert_includes primary.class.ancestors, ActiveRecordReplica::Extensions
    refute_same ActiveRecord::Base.connection_pool, ActiveRecordReplica::Replica.connection_pool
    assert_equal ActiveRecordReplica::Extensions, primary.method(:select_all).owner

    [false, true].each do |force_primary|
      query_paths = proc do
        name = force_primary ? 'primary' : 'replica'
        sql = 'SELECT name FROM users WHERE id = 1'
        assert_equal [name], User.where(id: 1).pluck(:name)
        assert User.exists?(name: name)
        refute User.exists?(name: force_primary ? 'replica' : 'primary')
        assert_equal name, User.find_by(id: 1).name
        assert_equal name, primary.select_one(sql).fetch('name')
        assert_equal name, primary.select_value(sql)
        assert_equal [[name]], primary.select_rows(sql)
        assert_equal [name], primary.select_values(sql)
        assert_equal [{'name' => name}], primary.select_all(sql).to_a
      end
      force_primary ? ActiveRecordReplica.read_from_primary(&query_paths) : query_paths.call
    end
  end

  def test_keyword_arguments_reach_the_adapter_on_both_pools
    [false, true].each do |force_primary|
      query = proc do
        # Arel makes select_all reach the adapter's private select with prepare:/async:.
        kwargs = ActiveRecord.version >= Gem::Version.new('7.0') ? { async: false } : {}
        kwargs[:allow_retry] = true if ActiveRecord.version >= Gem::Version.new('7.2')
        result = primary.select_all(User.where(id: 1).select(:name).arel, 'Keyword query', [], **kwargs)
        name = force_primary ? 'primary' : 'replica'
        assert_equal [name], result.rows.flatten
        if ActiveRecord.version >= Gem::Version.new('7.1')
          sql = 'SELECT name FROM users WHERE id = 1'
          assert_equal name, primary.select_one(sql, async: false).fetch('name')
          assert_equal name, primary.select_value(sql, async: false)
          assert_equal [[name]], primary.select_rows(sql, async: false)
        end
      end
      force_primary ? ActiveRecordReplica.read_from_primary(&query) : query.call
    end
  end

  def test_writes_use_primary_and_transactions_read_their_uncommitted_writes
    User.transaction do
      User.create!(id: 2, name: 'uncommitted')
      assert_equal %w[primary uncommitted], User.order(:id).pluck(:name)
      assert_equal %w[primary uncommitted], ActiveRecordReplica.read_from_replica { User.order(:id).pluck(:name) }
    end

    assert_equal ['replica'], User.order(:id).pluck(:name)
    assert_equal %w[primary uncommitted], ActiveRecordReplica.read_from_primary { User.order(:id).pluck(:name) }
  end

  def test_ignore_transactions_still_allows_an_explicit_primary_read
    ActiveRecordReplica.ignore_transactions = true
    User.transaction do
      User.create!(id: 2, name: 'uncommitted')
      assert_equal ['replica'], User.order(:id).pluck(:name)
      assert_equal %w[primary uncommitted], ActiveRecordReplica.read_from_primary { User.order(:id).pluck(:name) }
    end
  end

  if ActiveRecord.version >= Gem::Version.new('7.0')
    def test_load_async_uses_the_replica
      events = capture_sql do
        relation = User.where(id: 1).load_async
        assert relation.scheduled?, 'Async executor must schedule this query'
        # Consuming a pending future immediately lets Rails execute it in the foreground.
        future = relation.instance_variable_get(:@future_result)
        Timeout.timeout(5) { sleep 0.001 while future.pending? }
        assert_equal ['replica'], relation.map(&:name)
      end
      query = events.find { |event| event[:name] == 'Replica: User Load' }
      assert query, 'Expected a SQL event for the async query'
      assert query[:async], 'The query must use the asynchronous adapter path'
      assert_match(/\AReplica: /, query[:name])
    end
  else
    warn 'Active Record 6.1: load_async is unavailable; async coverage runs on 7.0–7.2.'
  end

  def test_block_transactions_prevents_materialized_transactions_and_savepoints
    ActiveRecordReplica.block_transactions do
      assert_raises(ActiveRecordReplica::TransactionAttempted) do
        User.transaction { primary.execute('SELECT 1') }
      end
      assert_raises(ActiveRecordReplica::TransactionAttempted) { primary.commit_db_transaction }
      %i[create_savepoint rollback_to_savepoint release_savepoint].each do |method|
        assert_raises(ActiveRecordReplica::TransactionAttempted) { primary.public_send(method, 'blocked') }
      end
    end
    refute ActiveRecordReplica.block_transactions?
    User.transaction { assert_equal ['primary'], User.pluck(:name) }
  end

  def test_skip_transactions_suppresses_transaction_and_savepoint_sql
    events = capture_sql do
      ActiveRecordReplica.skip_transactions do
        User.transaction { assert_equal ['primary'], User.pluck(:name) }
        %i[create_savepoint rollback_to_savepoint release_savepoint].each do |method|
          primary.public_send(method, 'skipped')
        end
      end
    end
    refute events.any? { |event| event[:sql].match?(/\A(?:BEGIN|COMMIT|SAVEPOINT|ROLLBACK|RELEASE)/i) }
    refute ActiveRecordReplica.skip_transactions?
  end

  def test_nested_savepoints_preserve_commit_and_rollback_behavior
    User.transaction do
      User.create!(id: 2, name: 'outer')
      User.transaction(requires_new: true) { User.create!(id: 3, name: 'nested') }
      User.transaction(requires_new: true) do
        User.create!(id: 4, name: 'rolled back')
        raise ActiveRecord::Rollback
      end
      assert_equal %w[primary outer nested], User.order(:id).pluck(:name)
    end
    assert_equal %w[primary outer nested], ActiveRecordReplica.read_from_primary { User.order(:id).pluck(:name) }
    assert_equal ['replica'], User.pluck(:name)
  end

  def test_savepoint_methods_accept_the_default_name
    User.transaction do
      # A write prevents Rails 7.2 from replacing the nested savepoint with a restartable transaction.
      User.where(id: 1).update_all(name: 'primary')
      User.transaction(requires_new: true) do
        primary.create_savepoint
        primary.execute("UPDATE users SET name = 'changed' WHERE id = 1")
        primary.rollback_to_savepoint
        primary.release_savepoint
        assert_equal ['primary'], User.pluck(:name)
        primary.create_savepoint # Rails will release its current savepoint when this block exits.
      end
    end
  end

  def test_routing_and_transaction_blocks_restore_state_after_exceptions
    ActiveRecordReplica.read_from_primary do
      assert_raises(RuntimeError) { ActiveRecordReplica.read_from_replica { raise 'restore routing' } }
      assert ActiveRecordReplica.read_from_primary?
    end
    assert ActiveRecordReplica.read_from_replica?

    ActiveRecordReplica.block_transactions do
      assert_raises(RuntimeError) { ActiveRecordReplica.skip_transactions { raise 'restore transactions' } }
      assert ActiveRecordReplica.block_transactions?
      refute ActiveRecordReplica.skip_transactions?
    end
    refute ActiveRecordReplica.block_transactions?
  end

  def test_replica_query_names_include_the_actual_name_or_sql_fallback
    events = capture_sql do
      primary.select_value('SELECT name FROM users WHERE id = 1', 'Marker query')
      primary.select_value('SELECT name FROM users WHERE id = 1')
    end
    assert_equal ['Replica: Marker query', 'Replica: SQL'], events.map { |event| event[:name] }
  end
end
