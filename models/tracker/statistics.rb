require "time"
require "json"
require "active_support/ordered_hash"
require File.expand_path("../../../lib/array_systematic_sample", __FILE__)

module UniversalTracker
  class Tracker
    module Statistics
      def queues
        resp = redis.pipelined do
          redis.keys("todo:d:*")
          redis.scard("todo")
          redis.scard("todo:secondary")
        end
        
        queues = []
        queues << { :key=>"todo",
                    :title=>"Main queue",
                    :length=>(resp[1].to_i + resp[2].to_i) }

        if resp[0].size > 0
          keys = resp[0].sort
          resp = redis.pipelined do
            keys.each do |queue|
              redis.scard(queue)
            end
          end.each_with_index do |length, index|
            if keys[index]=~/^todo:d:(.+)$/
              queues << { :key=>keys[index],
                          :title=>"Queue for #{ $1 }",
                          :length=>length.to_i }
            end
          end
        end

        queues
      end

      def requests_per_minute_history
        minutes = redis.keys("requests_processed:*")
        replies = redis.pipelined do
          minutes.each do |key|
            redis.get(key)
          end
        end
        minutes.zip(replies).map do |minute, requests|
          [ minute[/[0-9]+/], requests ]
        end.sort_by do |minute, requests|
          minute.to_i
        end
      end

      def number_of_claims
        redis.zcard("out")
      end

      def claims_per_downloader(regexp=nil)
        claims = redis.hgetall("claims")
        out = redis.zrange("out", 0, -1, :with_scores=>true)
        claims_per_downloader = ActiveSupport::OrderedHash.new{ |h,k| h[k] = [] }
        out.each_slice(2) do |item, time|
          if claims[item]
            ip, downloader = claims[item].split(" ", 2)
          else
            ip, downloader = "unknown", "unknown"
          end
          if regexp.nil? or item=~regexp
            claims_per_downloader[downloader] << { :item=>item,
                                                   :ip=>ip,
                                                   :since=>Time.at(time.to_i).utc }
          end
        end
        claims_per_downloader
      end

      def downloader_update_status
        resp = redis.pipelined do
          redis.hgetall("downloader_version")
          redis.get("current_version")
          redis.get("current_version_update_message")
        end
        data = {
          "downloader_version"=>Hash[*(resp[0] || [])],
          "current_version"=>resp[1],
          "current_version_update_message"=>resp[2]
        }
      end

      def stats
        resp = redis.pipelined do
          redis.hgetall("domain_bytes")
          redis.hgetall("downloader_bytes")
          redis.hgetall("downloader_count")
          redis.scard("done")
          redis.scard("todo")
          redis.scard("todo:secondary")
          redis.lrange("items_done_chartdata", 0, -1)
        end

        domain_bytes = Hash[*resp[0]]
        downloader_bytes = Hash[*resp[1]]
        downloader_count = Hash[*resp[2]]
        total_items_done = resp[3]
        total_items = resp[3].to_i + resp[4].to_i + resp[5].to_i
        items_done_chart = (resp[6] || []).systematic_sample(config.history_length).map do |item|
          JSON.parse(item)
        end

        downloaders = downloader_bytes.keys
        downloader_fields = downloaders.map{|d|"downloader_chartdata:#{ d }"}

        unless downloader_fields.empty?
          resp = redis.pipelined do
            downloader_fields.each do |fieldname|
              redis.lrange(fieldname, 0, -1)
            end
          end.map do |list|
            (list || []).systematic_sample(config.history_length).map do |item|
              JSON.parse(item)
            end
          end
          downloader_chart = Hash[downloaders.zip(resp)]
        else
          downloader_chart = {}
        end

        total_bytes = 0
        domain_bytes.each do |d, bytes|
          total_bytes += bytes.to_i
        end

        stats = {
          "domain_bytes"=>Hash[domain_bytes.map{ |k,v| [k, v.to_i] }],
          "downloader_bytes"=>Hash[downloader_bytes.map{ |k,v| [k, v.to_i] }],
          "downloader_count"=>Hash[downloader_count.map{ |k,v| [k, v.to_i] }],
          "downloader_chart"=>downloader_chart,
          "items_done_chart"=>items_done_chart,
          "downloaders"=>downloader_count.keys,
          "total_items_done"=>total_items_done.to_i,
          "total_items"=>total_items.to_i,
          "total_bytes"=>total_bytes
        }
      end
    end
  end
end

