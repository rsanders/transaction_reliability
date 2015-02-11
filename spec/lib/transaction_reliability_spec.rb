require 'spec_helper'
require 'pg'

describe TransactionReliability do

  class TrSpecTable < ActiveRecord::Base
    extend TransactionReliability::Helpers
    self.table_name = 'public.tr_spec_table'
  end

  class Foo
    extend TransactionReliability::Helpers
    def self.transaction(*args)
      puts "txn called with #{args.inspect}"
      yield
    end
  end

  # before(:all) do
  #   ActiveRecord::Base.connection.execute <<-SQL
  #     DROP TABLE IF EXISTS public.tr_spec_table;
  #     CREATE TABLE IF NOT EXISTS public.tr_spec_table
  #         (name text, num integer, ts timestamp);
  #   SQL
  #
  #   # ActiveRecord::Base.reset_column_information
  # end

  # after(:all) do
  #   ActiveRecord::Base.connection.execute <<-SQL
  #     DROP TABLE IF EXISTS public.tr_spec_table;
  #   SQL
  # end

  let! :conn1 do
    ActiveRecord::Base.connection_pool.checkout
  end

  let! :conn2 do
    ActiveRecord::Base.connection_pool.checkout
  end

  after(:each) do
    [conn1, conn2].each {|conn| ActiveRecord::Base.connection_pool.checkin(conn) }
  end

  let :counter do
    double('counter')
  end

  def fake_deadlock
    raise PG::TRDeadlockDetected, "PG::TRDeadlockDetected fake"
  end

  def fake_serialization_failure
    raise PG::TRSerializationFailure, "PG::TRSerializationFailure fake"
  end

  def fake_connection_lost
    raise PG::ConnectionBad, "PG::ConnectionBad fake"
  end

  class ActiveRecord::Base
    def self.transaction(*args)
      puts "calling fake .transaction() in AR::Base"
      yield
    end

    def self.connection
      double()
    end
  end

  context 'uncontended' do
    context 'transaction_with_retry' do
      it 'should run the block once' do
        counter.should_receive(:doit).exactly(1).times
        ActiveRecord::Base.should_receive(:transaction).exactly(1).times.and_call_original

        TransactionReliability.transaction_with_retry do
          counter.doit
        end
      end
    end

    context 'with_transaction_retry' do
      it 'should run the block once' do
        counter.should_receive(:doit).exactly(1).times
        ActiveRecord::Base.should_not_receive(:transaction)

        TransactionReliability.with_transaction_retry do
          counter.doit
        end
      end

      it 'should not re-run on ordinary failure' do
        counter.should_receive(:doit).exactly(1).times

        expect do
          TransactionReliability.with_transaction_retry do
            counter.doit
            raise ArgumentError
          end
        end.to raise_error(ArgumentError)
      end
    end

    context 'with simulated error on PG' do
      it 'should run the block the maximum number of times' do
        counter.should_receive(:doit).exactly(5).times

        expect do
          TransactionReliability.with_transaction_retry(backoff: 0) do
            counter.doit
            fake_deadlock
          end
        end.to raise_error
      end

      it 'should return TransactionReliability::DeadlockDetected error on unresolved deadlock' do
        expect do
          TransactionReliability.with_transaction_retry(retry_count: 1) do
            fake_deadlock
          end
        end.to raise_error(TransactionReliability::DeadlockDetected)
      end

      it 'should return TransactionReliability::SerializationFailure on unresolved serialization failure' do
        expect do
          TransactionReliability.with_transaction_retry(retry_count: 1) do
            fake_serialization_failure
          end
        end.to raise_error(TransactionReliability::SerializationFailure)
      end
    end

    context 'with simulated connection failure' do
      let :countup do
        [0]
      end

      let :connection do
        double('Connection')
      end

      before do
        ActiveRecord::Base.should_receive(:connection).at_least(1).times.and_return(connection)
      end

      it 'should retry the block' do
        counter.should_receive(:doit).exactly(5).times
        connection.should_receive(:reconnect!).at_least(1).times

        expect do
          TransactionReliability.with_transaction_retry(backoff: 0) do
            counter.doit
            fake_connection_lost
          end
        end.to raise_error
      end

      it 'should reconnect' do
        connection.should_receive(:reconnect!).exactly(1).times
        counter.should_receive(:doit).exactly(2).times

        TransactionReliability.with_transaction_retry(backoff: 0) do
          counter.doit
          countup[0] += 1
          fake_connection_lost if countup[0] == 1
        end
      end

      it 'should raise ConnectionLost if unresolved' do
        connection.should_receive(:reconnect!).at_least(1).times

        expect do
          TransactionReliability.with_transaction_retry(retry_count: 1, exit_on_disconnect: false) do
            fake_connection_lost
          end
        end.to raise_error(TransactionReliability::ConnectionLost)
      end

      it 'should call exit if the connection cannot be re-established and configured to exit' do
        connection.should_receive(:reconnect!).at_least(1).times

        expect do
          TransactionReliability.with_transaction_retry(retry_count: 1, exit_on_disconnect: true) do
            fake_connection_lost
          end
        end.to raise_error(SystemExit)
      end
    end
  end

  end
