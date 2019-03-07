require "stringio"

def subscription(name)
  Racecar::Consumer::Subscription.new(name, true, 1048576, {})
end

describe Racecar::ConsumerSet do
  let(:config)              { Racecar::Config.new }
  let(:rdconsumer)          { double("rdconsumer", subscribe: true) }
  let(:rdconfig)            { double("rdconfig", consumer: rdconsumer) }
  let(:consumer_set)        { Racecar::ConsumerSet.new(config, Logger.new(StringIO.new)) }
  let(:partition_eof_error) { Rdkafka::RdkafkaError.new(-191) }
  let(:max_poll_exceeded_error) { Rdkafka::RdkafkaError.new(-147) }

  def message_generator(messages)
    msgs = messages.dup
    proc do
      message = msgs.shift
      message.is_a?(StandardError) ? raise(message) : message
    end
  end

  before do
    allow(Rdkafka::Config).to receive(:new).and_return(rdconfig)
    allow(config).to receive(:subscriptions).and_return(subscriptions)
  end

  context "A consumer without subscription" do
    let(:subscriptions) { [] }

    it "raises an expeption" do
      expect { consumer_set }.to raise_error(ArgumentError)
    end
  end

  context "A consumer with subscription" do
    let(:subscriptions) { [ subscription("greetings") ] }

    it "subscribes to a topic upon first use" do
      allow(rdconsumer).to receive(:subscribe)

      consumer_set
      expect(rdconsumer).not_to have_received(:subscribe)

      consumer_set.current
      expect(rdconsumer).to have_received(:subscribe).with("greetings")
    end

    context "which is subscribed" do
      before { consumer_set; consumer_set.current }

      describe "#poll" do
        it "forwards to Rdkafka" do
          expect(rdconsumer).to receive(:poll).once.with(100).and_return(:message)
          expect(consumer_set.poll(100)).to be :message
        end

        it "returns nil on end of partition" do
          allow(rdconsumer).to receive(:poll).and_return(nil)
          expect(consumer_set.poll(100)).to be nil
        end

        it "sets last_poll_read_partition_eof? on partition end" do
          allow(rdconsumer).to receive(:poll).and_raise(partition_eof_error)

          expect {
            consumer_set.poll(100)
          }.to change {
            consumer_set.last_poll_read_partition_eof?
          }.from(false).to(true)
        end

        it "resets last_poll_read_partition_eof? on subsequent polls" do
          messages = [:msg1, partition_eof_error, :msg2, nil]
          allow(rdconsumer).to receive(:poll, &message_generator(messages))

          eofs = messages.map do
            consumer_set.poll(100)
            consumer_set.last_poll_read_partition_eof?
          end

          expect(eofs).to eq [false, true, false, false]
        end

        it "raises other Rdkafka errors" do
          allow(rdconsumer).to receive(:poll).and_raise(Rdkafka::RdkafkaError, 10) # msg_size_too_large
          allow(rdconsumer).to receive(:subscription)
          expect { consumer_set.poll(100) }.to raise_error(Rdkafka::RdkafkaError)
        end
      end

      describe "#batch_poll" do
        it "forwards to Rdkafka (as poll)" do
          config.fetch_messages = 3
          expect(rdconsumer).to receive(:poll).exactly(3).times.with(100).and_return(:msg1, :msg2, :msg3)
          expect(consumer_set.batch_poll(100)).to eq [:msg1, :msg2, :msg3]
        end

        it "returns remaining messages of current partition" do
          config.fetch_messages = 1000
          messages = [:msg1, :msg2, nil, :msgN]
          allow(rdconsumer).to receive(:poll, &message_generator(messages))

          expect(consumer_set.batch_poll(100)).to eq [:msg1, :msg2]
        end

        it "sets last_poll_read_partition_eof? on partition end" do
          config.fetch_messages = 1000
          allow(rdconsumer).to receive(:poll).and_raise(partition_eof_error)

          expect(consumer_set.batch_poll(100)).to eq []
          expect(consumer_set.last_poll_read_partition_eof?).to be true
        end

        it "returns messages until nil is encountered" do
          config.fetch_messages = 3
          allow(rdconsumer).to receive(:poll).and_return(:msg1, :msg2, nil, :msg3)
          expect(consumer_set.batch_poll(100)).to eq [:msg1, :msg2]
        end

        it "eventually reads all messages" do
          config.fetch_messages = 1
          messages = [:msg1, :msg2, nil, nil, partition_eof_error, partition_eof_error,  :msgN]
          allow(rdconsumer).to receive(:poll, &message_generator(messages))

          polled = []
          messages.size.times do
            polled += consumer_set.batch_poll(100) rescue []
          end
          expect(polled).to eq [:msg1, :msg2, :msgN]
        end

        it "passes messages xor raises EOF" do
          config.fetch_messages = 2
          messages = [:msg1, partition_eof_error, partition_eof_error, :msg2]
          allow(rdconsumer).to receive(:poll, &message_generator(messages))

          polled = []
          messages.size.times do
            polled += consumer_set.batch_poll(100) rescue []
          end
          expect(polled).to eq [:msg1, :msg2]
        end

        it "raises other Rdkafka errors" do
          allow(rdconsumer).to receive(:poll).and_raise(Rdkafka::RdkafkaError, 10) # msg_size_too_large
          allow(rdconsumer).to receive(:subscription)
          expect { consumer_set.batch_poll(100) }.to raise_error(Rdkafka::RdkafkaError)
        end
      end

      describe "#commit" do
        it "forwards to Rdkafka" do
          expect(rdconsumer).to receive(:commit).once
          consumer_set.commit
        end

        it "does not raise when there is nothing to commit" do
          expect(rdconsumer).to receive(:commit).once.and_raise(Rdkafka::RdkafkaError, -168) # no_offset
          consumer_set.commit
        end
      end

      describe "#close" do
        it "forwards to Rdkafka" do
          expect(rdconsumer).to receive(:close).once
          consumer_set.close
        end
      end

      describe "#current" do
        it "returns current rdkafka client" do
          expect(consumer_set.current).to be rdconsumer
        end
      end
    end
  end

  context "A consumer with multiple subscriptions" do
    let(:subscriptions) { [ subscription("feature"), subscription("profile"), subscription("account") ] }
    let(:rdconsumer1)   { double("rdconsumer_feature", subscribe: true) }
    let(:rdconsumer2)   { double("rdconsumer_profile", subscribe: true) }
    let(:rdconsumer3)   { double("rdconsumer_account", subscribe: true) }

    before do
      allow(rdconfig).to receive(:consumer).and_return(rdconsumer1, rdconsumer2, rdconsumer3)
    end

    it ".new subscribes to all topics" do
      expect(rdconsumer1).to receive(:subscribe).with("feature")
      expect(rdconsumer2).to receive(:subscribe).with("profile")
      expect(rdconsumer3).to receive(:subscribe).with("account")

      3.times do
        consumer_set.current
        consumer_set.send(:select_next_consumer)
      end
    end

    it ".new subscribes lazily" do
      expect(rdconsumer1).to receive(:subscribe).with("feature")
      expect(rdconsumer2).to receive(:subscribe).never
      expect(rdconsumer3).to receive(:subscribe).never

      consumer_set.current
      consumer_set.send(:select_next_consumer)
    end

    it "#reset_current_consumer does what it says" do
      3.times do
        consumer_set.current
        consumer_set.send(:select_next_consumer)
      end
      consumer_set.send(:select_next_consumer)

      expect do
        consumer_set.send(:reset_current_consumer)
      end.to change {
        consumer_set.instance_variable_get(:@consumers)[1]
      }.from(rdconsumer2).to(nil)
    end

    it "#current recreates resetted consumers" do
      3.times do
        consumer_set.current
        consumer_set.send(:select_next_consumer)
      end
      consumer_set.send(:select_next_consumer)
      consumer_set.send(:reset_current_consumer)

      expect(consumer_set.current).not_to be_nil
    end

    it "#current returns current rdkafka client" do
      expect(consumer_set.current).to be rdconsumer1
    end

    it "#poll retries once upon max poll exceeded" do
      raised = false
      allow(rdconsumer1).to receive(:poll) do
        next nil if raised
        raised = true
        raise(max_poll_exceeded_error)
      end
      allow(rdconsumer2).to receive(:poll).and_return(nil)
      allow(rdconsumer3).to receive(:poll)
      allow(consumer_set).to receive(:reset_current_consumer)

      consumer_set.poll(100)
      consumer_set.poll(100)

      expect(consumer_set).to have_received(:reset_current_consumer).once
      expect(rdconsumer1).to have_received(:poll).twice
      expect(rdconsumer2).to have_received(:poll).once
      expect(rdconsumer3).not_to have_received(:poll)
    end

    it "#poll changes rdkafka client on end of partition" do
      allow(rdconsumer1).to receive(:poll).and_return(nil)
      expect(consumer_set.poll(100)).to be nil
      expect(consumer_set.current).to be rdconsumer2
    end

    it "#poll changes rdkafka client when partition EOF is raised" do
      allow(rdconsumer1).to receive(:poll).and_raise(partition_eof_error)
      consumer_set.poll(100)
      expect(consumer_set.current).to be rdconsumer2
    end

    it "#batch_poll changes rdkafka client on end of partition" do
      config.fetch_messages = 1000
      messages = [:msg1, :msg2, nil, :msgN]
      allow(rdconsumer1).to receive(:poll, &message_generator(messages))

      expect(consumer_set.batch_poll(100)).to eq [:msg1, :msg2]
      expect(consumer_set.current).to be rdconsumer2
    end

    it "#batch_poll changes rdkafka client when partition EOF is raised" do
      allow(rdconsumer1).to receive(:poll).and_raise(partition_eof_error)
      consumer_set.batch_poll(100)
      expect(consumer_set.current).to be rdconsumer2
    end

    it "#batch_poll sets last_poll_read_partition_eof? on partition end" do
      allow(rdconsumer1).to receive(:poll).and_raise(partition_eof_error)

      expect {
        consumer_set.poll(100)
      }.to change {
        consumer_set.last_poll_read_partition_eof?
      }.from(false).to(true)
    end

    it "#batch_poll resets last_poll_read_partition_eof? on subsequent polls" do
      allow(rdconsumer1).to receive(:poll).and_raise(partition_eof_error)
      allow(rdconsumer2).to receive(:poll).and_return(nil)

      expect {
        consumer_set.poll(100)
        consumer_set.poll(100)
      }.not_to change {
        consumer_set.last_poll_read_partition_eof?
      }
    end

    it "#batch_poll changes rdkafka client when encountering a nil message" do
      config.fetch_messages = 1000
      messages = [:msg1, :msg2, nil, :msgN]
      allow(rdconsumer1).to receive(:poll, &message_generator(messages))

      expect(consumer_set.batch_poll(100)).to eq [:msg1, :msg2]
      expect(consumer_set.current).to be rdconsumer2
    end

    it "#batch_poll eventually reads all messages" do
      config.fetch_messages = 1
      messages = [:msg1, nil, nil, partition_eof_error, partition_eof_error, :msgN]
      allow(rdconsumer1).to receive(:poll, &message_generator(messages))
      allow(rdconsumer2).to receive(:poll, &message_generator(messages))
      allow(rdconsumer3).to receive(:poll, &message_generator(messages))

      polled = []
      count = (messages.size+1)*3
      count.times { polled += consumer_set.batch_poll(100) rescue [] }
      expect(polled).to eq [:msg1, :msg1, :msg1, :msgN, :msgN, :msgN]
    end
  end
end
