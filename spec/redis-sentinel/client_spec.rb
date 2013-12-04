require "spec_helper"

describe Redis::Client do
  let(:client) { double("Client", :reconnect => true) }
  let(:redis)  { double("Redis", :sentinel => ["remote.server", 8888], :client => client) }

  let(:sentinels) do
    [
      {:host => "localhost", :port => 26379},
      {:host => "localhost", :port => 26380}
    ]
  end

  subject { Redis::Client.new(:master_name => "master", :master_password => "foobar",
                              :sentinels => sentinels) }

  before do
    sentinels.stub(:shuffle!)
    Redis.stub(:new).and_return(redis)
  end

  context "#initialize" do

    it "shuffles the sentinel array" do
      sentinels.should_receive(:shuffle!)
      subject
    end

  end

  context "#sentinel?" do
    it "should be true if passing sentiels and master_name options" do
      expect(Redis::Client.new(:master_name => "master", :sentinels => [{:host => "localhost", :port => 26379}, {:host => "localhost", :port => 26380}])).to be_sentinel
    end

    it "should not be true if not passing sentinels and master_name options" do
      expect(Redis::Client.new).not_to be_sentinel
    end

    it "should not be true if passing sentinels option but not master_name option" do
      expect(Redis::Client.new(:sentinels => [{:host => "localhost", :port => 26379}, {:host => "localhost", :port => 26380}])).not_to be_sentinel
    end

    it "should not be true if passing master_name option but not sentinels option" do
      expect(Redis::Client.new(:master_name => "master")).not_to be_sentinel
    end
  end

  context "#try_next_sentinel" do
    it "should return next sentinel server" do
      expect(subject.try_next_sentinel).to eq({:host => "localhost", :port => 26380})
    end
  end

  context "#discover_master" do
    it "gets the current master" do
      redis.should_receive(:sentinel).
            with("get-master-addr-by-name", "master")
      redis.should_receive(:sentinel).
            with("is-master-down-by-addr", "remote.server", 8888)
      subject.discover_master
    end

    it "should update options" do
      redis.should_receive(:sentinel).
            with("is-master-down-by-addr", "remote.server", 8888).once.
            and_return([0, "abc"])
      subject.discover_master
      expect(subject.host).to eq "remote.server"
      expect(subject.port).to eq 8888
      expect(subject.password).to eq "foobar"
    end

    it "should not update options before newly promoted master is ready" do
      redis.should_receive(:sentinel).
            with("is-master-down-by-addr", "remote.server", 8888).twice.
            and_return([1, "abc"], [0, "?"])
      2.times do
        expect do
          subject.discover_master
        end.to raise_error(Redis::CannotConnectError, /currently not available/)
        expect(subject.host).not_to eq "remote.server"
        expect(subject.port).not_to eq 8888
        expect(subject.password).not_to eq "foobar"
      end
    end

    it "should not use a password" do
      Redis.should_receive(:new).with({:host => "localhost", :port => 26379})
      redis.should_receive(:sentinel).with("get-master-addr-by-name", "master")
      redis.should_receive(:sentinel).with("is-master-down-by-addr", "remote.server", 8888)

      redis = Redis::Client.new(:master_name => "master", :sentinels => [{:host => "localhost", :port => 26379}])
      redis.discover_master

      expect(redis.host).to eq "remote.server"
      expect(redis.port).to eq 8888
      expect(redis.password).to eq nil
    end

    it "should select next sentinel" do
      Redis.should_receive(:new).with({:host => "localhost", :port => 26379})
      redis.should_receive(:sentinel).
            with("get-master-addr-by-name", "master").
            and_raise(Redis::CannotConnectError)
      Redis.should_receive(:new).with({:host => "localhost", :port => 26380})
      redis.should_receive(:sentinel).
            with("get-master-addr-by-name", "master")
      redis.should_receive(:sentinel).
            with("is-master-down-by-addr", "remote.server", 8888)
      subject.discover_master
      expect(subject.host).to eq "remote.server"
      expect(subject.port).to eq 8888
      expect(subject.password).to eq "foobar"
    end

    describe "memoizing sentinel connections" do
      it "does not reconnect to the sentinels" do
        Redis.should_receive(:new).once

        subject.discover_master
        subject.discover_master
      end
    end
  end

  context "#auto_retry_with_timeout" do
    context "no failover reconnect timeout set" do
      subject { Redis::Client.new }

      it "does not sleep" do
        subject.should_not_receive(:sleep)
        expect do
          subject.auto_retry_with_timeout { raise Redis::CannotConnectError }
        end.to raise_error(Redis::CannotConnectError)
      end
    end

    context "the failover reconnect timeout is set" do
      subject { Redis::Client.new(:failover_reconnect_timeout => 3) }

      before(:each) do
        subject.stub(:sleep)
      end

      it "only raises after the failover_reconnect_timeout" do
        called_counter = 0
        Time.stub(:now).and_return(100, 101, 102, 103, 104, 105)

        begin
          subject.auto_retry_with_timeout do
            called_counter += 1
            raise Redis::CannotConnectError
          end
        rescue Redis::CannotConnectError
        end

        called_counter.should == 4
      end

      it "sleeps the default wait time" do
        Time.stub(:now).and_return(100, 101, 105)
        subject.should_receive(:sleep).with(0.1)
        begin
          subject.auto_retry_with_timeout { raise Redis::CannotConnectError }
        rescue Redis::CannotConnectError
        end
      end

      it "does not catch other errors" do
        subject.should_not_receive(:sleep)
        expect do
          subject.auto_retry_with_timeout { raise Redis::ConnectionError }
        end.to raise_error(Redis::ConnectionError)
      end

      context "configured wait time" do
        subject { Redis::Client.new(:failover_reconnect_timeout => 3,
                                    :failover_reconnect_wait => 0.01) }

        it "uses the configured wait time" do
          Time.stub(:now).and_return(100, 101, 105)
          subject.should_receive(:sleep).with(0.01)
          begin
            subject.auto_retry_with_timeout { raise Redis::CannotConnectError }
          rescue Redis::CannotConnectError
          end
        end
      end
    end
  end

  context "#disconnect" do
    it "calls disconnect on each sentinel client" do
      subject.stub(:connect)
      subject.discover_master
      subject.send(:redis_sentinels).each do |config, sentinel|
        sentinel.client.should_receive(:disconnect)
      end

      subject.disconnect
    end
  end

  context "#reconnect" do
    it "effectively reconnects on each sentinel client" do
      subject.stub(:connect)
      subject.discover_master

      subject.send(:redis_sentinels).each do |config, sentinel|
        sentinel.client.should_receive(:disconnect)
      end
      # we assume that subject.connect will connect to a sentinel
      subject.should_receive(:connect)

      subject.reconnect
    end
  end

end
