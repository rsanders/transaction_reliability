require 'spec_helper'

describe TransactionReliability do
  before(:all) do
    ActiveRecord::Base.connection.execute <<-SQL
      DROP TABLE IF EXISTS public.tr_spec_table;
      CREATE TABLE IF NOT EXISTS public.tr_spec_table
          (name text, num integer, ts timestamp);
    SQL
  end

  after(:all) do
    ActiveRecord::Base.connection.execute <<-SQL
      DROP TABLE IF EXISTS public.tr_spec_table;
    SQL
  end


end
