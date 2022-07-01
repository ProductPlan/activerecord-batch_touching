require "activerecord/batch_touching/version"
require "activerecord/batch_touching/state"

module ActiveRecord
  # = Active Record Batch Touching
  module BatchTouching # :nodoc:
    extend ActiveSupport::Concern

    # Override ActiveRecord::Base#touch_later.  This will effectively disable the current built-in mechanism AR uses
    # to delay touching in favor of our method of batch touching.
    def touch_later(*names)
      touch(*names)
    end

    # Override ActiveRecord::Base#touch.  If currently batching touches, always return
    # true because there's no way to tell if the write would have failed.
    def touch(*names, time: nil)
      if BatchTouching.batch_touching? && !no_touching?
        add_to_transaction
        BatchTouching.add_record(self, names)
        true
      else
        super
      end
    end

    # These get added as class methods to ActiveRecord::Base.
    module ClassMethods
      # Batches up +touch+ calls for the duration of a transaction.
      # +after_touch+ callbacks are also delayed until the transaction is committed.
      #
      # ==== Examples
      #
      #   # Touches Person.first and Person.last in a single database round-trip.
      #   Person.transaction do
      #     Person.first.touch
      #     Person.last.touch
      #   end
      #
      #   # Touches Person.first once, not twice, right before the transaction is committed.
      #   Person.transaction do
      #     Person.first.touch
      #     Person.first.touch
      #   end
      #
      def transaction(**options, &block)
        super(**options) do
          BatchTouching.start(**options, &block)
        end
      end
    end

    class << self
      def states
        Thread.current[:batch_touching_states] ||= []
      end

      def current_state
        states.last
      end

      delegate :add_record, to: :current_state

      def batch_touching?
        states.present?
      end

      # Start batching all touches. When done, apply them. (Unless nested.)
      def start(options = {})
        states.push State.new
        yield.tap do
          apply_touches if states.length == 1
        end
      ensure
        merge_transactions unless $! && options[:requires_new]

        # Decrement nesting even if +apply_touches+ raised an error. To ensure the stack of States
        # is empty after the top-level transaction exits.
        states.pop
      end

      # When exiting a nested transaction, merge the nested transaction's
      # touched records with the outer transaction's touched records.
      def merge_transactions
        states[-2].merge!(current_state) if states.length > 1
      end

      # Apply the touches that were batched. We're in a transaction already so there's no need to open one.
      def apply_touches
        callbacks_run = Set.new
        all_states = State.new
        while current_state.more_records?
          all_states.merge!(current_state)
          state_records = current_state.records
          current_state.clear_records!
          state_records.each do |_, records|
            # Run callbacks to collect more touches (i.e. touch: true for associations)
            records.each do |record|
              unless callbacks_run.include?(record)
                record._run_touch_callbacks
                callbacks_run.add(record)
              end
            end
          end
        end

        # Sort by class name. Having a consistent order can help mitigate deadlocks.
        sorted_records = all_states.records.keys.sort_by { |k| k.first.name }.map { |k| [k, all_states.records[k]] }.to_h
        sorted_records.each do |(klass, columns), records|
          touch_records klass, columns, records
        end
      end

      # Touch the specified records--non-empty set of instances of the same class.
      def touch_records(klass, columns, records)
        if columns.present?
          current_time = records.first.send(:current_time_from_proper_timezone)

          records.each do |record|
            record.instance_eval do
              columns.each { |column| write_attribute column, current_time }
              if locking_enabled?
                self[self.class.locking_column] += 1
                clear_attribute_change(self.class.locking_column)
              end
              clear_attribute_changes(columns)
            end
          end

          sql = columns.map { |column| "#{klass.connection.quote_column_name(column)} = :current_time" }.join(", ")
          sql += ", #{klass.locking_column} = #{klass.locking_column} + 1" if klass.locking_enabled?

          klass.unscoped.where(klass.primary_key => records.to_a).update_all([sql, current_time: current_time])
        end
      end
    end
  end
end

ActiveRecord::Base.include ActiveRecord::BatchTouching
