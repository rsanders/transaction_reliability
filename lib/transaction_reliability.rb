#
# Provide utilities for the (more) reliable handling of database errors 
# related to concurrency or connectivity.
#
# Currently only handles Postgresql and Mysql, assuming use of
# the PG and Mysql2 drivers respectively
#
module TransactionReliability

  # 
  # We inherit from StatementInvalid because of compatibility with 
  # all the code which may rescue StatementInvalid
  # 
  class TransientTransactionError < ActiveRecord::StatementInvalid
  end

  #
  # Parent class for deadlocks, serialization failures, and other
  # non-fatal errors that can be handled by retrying a transaction
  #
  class ConcurrencyError < TransientTransactionError
  end

  #
  # There has been an unresolvable write conflict between two transactions
  #
  class DeadlockDetected < ConcurrencyError
  end

  #
  # For transaction in isolation level SERIALIZABLE, some conflict
  # has been detected. The transaction should be retried.
  #
  class SerializationFailure < ConcurrencyError
  end

  #
  # The connection to the database has been lost.
  #
  class ConnectionLost < TransientTransactionError
  end

  module Helpers
    #
    # Intended to be included in an ActiveRecord model class.
    #
    # Retries a block (which usually contains a transaction) under certain
    # failure conditions, up to a configurable number of times with an
    # exponential backoff delay between each attempt.
    #
    # Conditions for retrying:
    #
    #    1. Database connection lost
    #    2. Query or txn failed due to detected deadlock 
    #       (Mysql/InnoDB and Postgres can both signal this for just about 
    #        any transaction)
    #    3. Query or txn failed due to serialization failure 
    #       (Postgres will signal this for transactions in isolation 
    #        level SERIALIZABLE)
    #
    # options: 
    #    retry_count  - how many retries to make; default 4
    #
    #    backoff      - time period before 1st retry, in fractional seconds.
    #                   will double at every retry. default 0.25 seconds.
    #
    #    exit_on_disconnect 
    #                 - whether to call exit if no retry succeeds and
    #                   the cause is a failed connection
    #
    #    exit_on_fail - whether to call exit if no retry succeeds
    #
    # defaults:
    #    
    #
    def with_transaction_retry(options = {})
      retry_count         = options.fetch(:retry_count,            4)
      backoff             = options.fetch(:backoff,             0.25)
      exit_on_fail        = options.fetch(:exit_on_fail,       false)
      exit_on_disconnect  = options.fetch(:exit_on_disconnect,  true)
      connection          = options[:connection] || ActiveRecord::Base.connection

      count               = 0

      # list of exceptions we may catch
      exceptions = ['ActiveRecord::StatementInvalid', 'PG::Error', 'Mysql2::Error'].
                     map {|name| name.safe_constantize}.
                     compact

      #
      # There are times when, for example, 
      # a raw PG::Error is throw rather than a wrapped ActiveRecord::StatementInvalid
      #
      # Also, connector-specific classes like PG::Error may not be defined
      #
      begin
        connection_lost = false
        yield
      rescue *exceptions => e
        translated = TransactionReliability.rewrap_exception(e)

        case translated
          when ConnectionLost
            Rails.logger.error "Connection to postgres lost: #{e.class}:#{e.message}"
            ActiveRecord::Base.connection.reconnect!
            connection_lost = true
          when DeadlockDetected, SerializationFailure
            Rails.logger.info "Transaction had concurrency failure (#{translated.class}; #{translated.message})."
          else
            raise translated
        end

        # Retry up to retry_count times
        if count < retry_count
          sleep backoff
          count   += 1
          backoff *= 2
          retry
        else
          Rails.logger.fatal "Transaction failed after #{count} tries; giving up."
          if (connection_lost && exit_on_disconnect) || exit_on_fail
            exit
          else 
            raise(translated)
          end
        end
      end
    end

    #
    # Execute some code in a DB transaction, with retry
    #
    def transaction_with_retry(txn_options = {}, retry_options = {})
      base_obj = self.respond_to?(:transaction) ? self : ActiveRecord::Base

      with_transaction_retry(retry_options) do
        base_obj.transaction(txn_options) do
          yield
        end
      end
    end
  end

  # allow the helper methods to be accessed as methods on this module
  extend(Helpers)

  #
  # Unwrap ActiveRecord::StatementInvalid into some more specific exceptions
  # that we define.
  #
  # Only defined for Mysql2 and PG drivers at the moment
  #
  def self.rewrap_exception(exception)
    if exception.message.start_with?('PG::') || exception.class.name.start_with?('PG::')
      rewrap_pg_exception exception
    elsif exception.message =~ /^mysql2::/i
      rewrap_mysql2_exception exception
    else
      exception
    end
  end

  protected

  SQLSTATE_CONNECTION_ERRORS = 
            [
              '08000',   # connection_exception
              '08003',   # connection_does_not_exist
              '08006',   # connection_failure
              '08001',   # sqlclient_unable_to_establish_sqlconnection
              '08004',   # sqlserver_rejected_establishment_of_sqlconnection
              '08007',   # transaction_resolution_unknown
              '08P01'    # protocol_violation
            ]

  SQLSTATE_DEADLOCK_ERRORS = 
            [
              '40P01'    # deadlock detected
            ]

  SQLSTATE_ISOLATION_ERRORS = 
            [
              '40001'    # serialization failure
            ]


  def self.rewrap_pg_exception(exception)
    message = exception.message
    orig    = case
              when exception.is_a?(PG::Error)
                exception
              when exception.respond_to?(:original_exception)
                exception.original_exception
              else
                exception
              end

    if orig.is_a? PG::Error
      sqlstate = orig.result.result_error_field(PGresult::PG_DIAG_SQLSTATE) rescue nil
    else
      sqlstate = nil
    end

    case
      when orig.is_a?(PG::ConnectionBad)           || SQLSTATE_CONNECTION_ERRORS.include?(sqlstate)
        ConnectionLost.new(message, orig)
      when orig.is_a?(PG::TRDeadlockDetected)      || SQLSTATE_DEADLOCK_ERRORS.include?(sqlstate)
        DeadlockDetected.new(message, orig)
      when orig.is_a?(PG::TRSerializationFailure)  || SQLSTATE_ISOLATION_ERRORS.include?(sqlstate)
        SerializationFailure.new(message, orig)
      else
        exception
    end
  end

  #
  # Ugh. This may not work if you're using non-English localization
  # for your MySQL server.
  #
  def self.rewrap_mysql_exception(exception)
    orig    = exception.original_exception
    message = exception.message

    case 
    when message =~ /Serialization failure/i
      SerializationFailure.new(message, orig)
    when message =~ /Deadlock found when trying to get lock/i || 
         message =~ /Lock wait timeout exceeded/i
      DeadlockDetected.new(message, orig)
    when message =~ /Lost connection to MySQL server/i        ||
         message =~ /Invalid connection handle/i              ||
         message =~ /MySQL server has gone away/i             ||
         message =~ /Broken pipe/i                            ||
         message =~ /Server shutdown in progress/i
      ConnectionLost.new(message, orig)
    else
      exception
    end
  end
end

