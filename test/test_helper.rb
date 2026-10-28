ENV['RAILS_ENV'] = 'test'

require 'logger'
require 'erb'
require 'yaml'
require 'timeout'
require 'active_record'
require 'mysql2'
require 'minitest/autorun'
require 'active_record_replica'

ActiveRecord::Base.logger = Logger.new(File.expand_path('../test.log', __dir__))
ActiveRecord::Base.configurations = YAML.safe_load(ERB.new(File.read(File.join(__dir__, 'database.yml'))).result)
primary_config = ActiveRecord::Base.configurations.configs_for(env_name: 'test').first.configuration_hash
reader_config = primary_config.fetch(:reader).symbolize_keys
raise 'Tests need distinct primary and replica databases' if primary_config[:database] == reader_config[:database]

# These databases intentionally do not replicate. Different rows prove which pool executes a read.
[primary_config, reader_config].each do |config|
  client = Mysql2::Client.new(config.except(:adapter, :database, :reader, :pool))
  database = config.fetch(:database)
  raise 'Invalid test database name' unless database.match?(/\A[a-zA-Z0-9_]+\z/)

  client.query("CREATE DATABASE IF NOT EXISTS `#{database}`")
  client.close
end

ActiveRecord.async_query_executor = :global_thread_pool if ActiveRecord.respond_to?(:async_query_executor=)
ActiveRecord::Base.establish_connection(:test)
ActiveRecordReplica.install!(nil, 'test')

ActiveRecordReplica.read_from_primary do
  [ActiveRecord::Base.connection, ActiveRecordReplica::Replica.connection].each do |connection|
    connection.create_table(:users, force: true) { |table| table.string :name }
    connection.disable_query_cache!
  end
end

class User < ActiveRecord::Base
end

class ReplicaTest < Minitest::Test
  def setup
    @routing = Thread.current.thread_variable_get(:active_record_replica)
    @transactions = Thread.current.thread_variable_get(:active_record_replica_transaction)
    @ignore_transactions = ActiveRecordReplica.ignore_transactions?
    ActiveRecordReplica.read_from_replica!
    Thread.current.thread_variable_set(:active_record_replica_transaction, nil)
    ActiveRecordReplica.ignore_transactions = false

    [primary, reader].zip(%w[primary replica]).each do |connection, name|
      connection.execute('DELETE FROM users')
      connection.execute("INSERT INTO users (id, name) VALUES (1, #{connection.quote(name)})")
      connection.clear_query_cache
    end
  end

  def teardown
    Thread.current.thread_variable_set(:active_record_replica, @routing)
    Thread.current.thread_variable_set(:active_record_replica_transaction, @transactions)
    ActiveRecordReplica.ignore_transactions = @ignore_transactions
  end

  def primary
    ActiveRecord::Base.connection
  end

  def reader
    ActiveRecordReplica::Replica.connection
  end

  def capture_sql
    events = []
    callback = proc { |*arguments| events << arguments.last }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield events }
    events
  end
end
