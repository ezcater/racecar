module Racecar
  class ConsumerSet
    def initialize(config, logger)
      @config, @logger = config, logger
      @consumers = []
      @consumer_iterator = [].cycle

      # for batch support
      @messages = []
      @last_batch = Time.now
    end

    def subscribe
      raise ArgumentError, "Subscriptions must not be empty when subscribing" if @config.subscriptions.empty?
      @consumers = @config.subscriptions.map do |subscription|
        # https://github.com/edenhill/librdkafka/blob/master/CONFIGURATION.md
        config = {
          "bootstrap.servers": @config.brokers.join(","),
          "group.id":          @config.group_id,
          "client.id":         @config.client_id,
          "auto.offset.reset": "earliest",
        }
        config.merge!(@config.rdkafka_consumer)
        config.merge!(subscription.config)
        consumer = Rdkafka::Config.new(config).consumer
        consumer.subscribe(subscription.topic)
        consumer
      end
      @consumer_iterator = @consumers.cycle
      @consumers
    end

    def poll(timeout_ms)
      current.poll(timeout_ms)
    rescue Rdkafka::RdkafkaError => e
      raise if e.message != "Broker: No more messages (partition_eof)"
      @logger.debug "No more messages on this partition."
      @consumer_iterator.next
      nil
    end

    def batch_poll(timeout_ms)
      @messages = []
      @messages << current.poll(timeout_ms) while collect_messages_for_batch?
      @last_batch = Time.now
      @messages.compact
    rescue Rdkafka::RdkafkaError => e
      raise if e.message != "Broker: No more messages (partition_eof)"
      @logger.debug "No more messages on this partition."
      @consumer_iterator.next
      @last_batch = Time.now
      @messages.compact
    end

    def commit
      each do |consumer|
        consumer.commit(nil, !@config.synchonous_commits)
      rescue Rdkafka::RdkafkaError => e
        raise e if e.message != "Local: No offset stored (no_offset)"
        @logger.debug "Nothing to commit."
      end
    end

    def close
      each(&:close)
    end

    def current
      @consumer_iterator.peek
    end

    def each
      @consumers.each
    end

    private

    def collect_messages_for_batch?
      @messages.size < @config.fetch_messages &&
      (Time.now - @last_batch) < @config.fetch_wait_max
    end
  end
end
