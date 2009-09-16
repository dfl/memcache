require 'active_record'

class Memcache
  class DBServer
    attr_reader :db, :table

    def initialize(opts)
      @table = opts[:table]
      @db    = opts[:db] || ActiveRecord::Base.connection.raw_connection
    end

    def name
      @name ||= begin
        db_config = db.instance_variable_get(:@config)
        "#{db_config[:host]}:#{db_config[:database]}:#{table}"
      end
    end

    def flush_all(delay = nil)
      db.query("TRUNCATE #{table}")
    end

    def get(keys)
      return get([keys])[keys.to_s] unless keys.kind_of?(Array)

      keys = keys.collect {|key| quote(key.to_s)}.join(',')
      sql = %{
        SELECT key, value FROM #{table}
          WHERE key IN (#{keys}) AND #{expiry_clause}
      }
      results = {}
      db.query(sql).each do |key, value|
        results[key] = value
      end
      results
    end

    def incr(key, amount = 1)
      transaction do
        value = get(key)
        return unless value        
        return unless value =~ /^\d+$/
        
        value = value.to_i + amount
        value = 0 if value < 0
        db.query %{
          UPDATE #{table} SET value = #{quote(value)}, updated_at = NOW()
            WHERE key = #{quote(key)}
        }
        value
      end
    end

    def decr(key, amount = 1)
      incr(key, -amount)
    end

    def delete(key, expiry = 0)
      if expiry
        db.query %{
          UPDATE #{table} SET expires_at = NOW() + interval '#{expiry} seconds'
           WHERE key = #{quote(key)} AND #{expiry_clause(expiry)}
        }
      else
        db.query %{
          DELETE FROM #{table}
           WHERE key = #{quote(key)}
        }
      end
    end

    def set(key, value, expiry = 0)
      transaction do
        if exists?(key)
          update(key, value, expiry)
        else
          insert(key, value, expiry)
        end
      end
    end

    def add(key, value, expiry = 0)
      transaction do
        delete_expired(key)
        insert(key, value, expiry)
      end
    rescue PGError => e
      nil
    end

    def replace(key, value, expiry = 0)      
      transaction do
        delete_expired(key)
        update(key, value, expiry)
      end
      value
    end

  private
 
    def insert(key, value, expiry = 0)
      db.query %{
        INSERT INTO #{table} (key, value, updated_at, expires_at)
          VALUES (#{quote(key)}, #{quote(value)}, NOW(), #{expiry_sql(expiry)})
      }
    end

    def update(key, value, expiry = 0)
      db.query %{
        UPDATE #{table}
          SET value = #{quote(value)}, updated_at = NOW(), expires_at = #{expiry_sql(expiry)}
          WHERE key = #{quote(key)}
      }
    end

    def exists?(key)
      result = db.query %{
        SELECT key FROM #{table}
          WHERE key = #{quote(key)}
      }
      result.any?
    end

    def transaction
      return yield if @in_transaction
      
      begin 
        @in_transaction = true
        db.query('BEGIN')
        value = yield
        db.query('COMMIT')
        value
      rescue Exception => e
        db.query('ROLLBACK')
        raise e
      ensure
        @in_transaction = false
      end
    end
      
    def quote(string)
      string.to_s.gsub(/'/,"\'")
      "'#{string}'"
    end

    def delete_expired(key)
      db.query "DELETE FROM #{table} WHERE key = #{quote(key)} AND NOT (#{expiry_clause})"
    end
    
    def expiry_clause(expiry = 0)
      "expires_at IS NULL OR expires_at > '#{expiry == 0 ? 'NOW()' : expiry_sql(expiry)}'"
    end

    def expiry_sql(expiry)
      expiry == 0 ? 'NULL' : "NOW() + interval '#{expiry} seconds'"
    end
  end
end

class MemcacheDBMigration < ActiveRecord::Migration
  class << self
    attr_accessor :table
  end

  def self.up
    create_table table, :id => false do |t|
      t.string    :key
      t.text      :value
      t.timestamp :expires_at
      t.timestamp :updated_at
    end

    add_index table, [:key], :unique => true
    add_index table, [:expires_at]
  end

  def self.down
    drop_table table
  end
end
