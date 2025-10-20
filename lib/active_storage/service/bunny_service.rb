# frozen_string_literal: true

require 'active_support/core_ext/numeric/bytes'
require 'cgi'
require 'bunny_storage_client'

module ActiveStorage
  # Wraps the BunnyCDN Storage as an Active Storage service.
  # See ActiveStorage::Service for the generic API documentation that applies to all services.
  class Service::BunnyService < Service

    attr_reader :client, :base_url, :access_key, :storage_zone, :region

    def initialize(access_key:, api_key:, storage_zone:, region:, cdn: false)
      @access_key = access_key
      @storage_zone = storage_zone
      @region = blank_to_nil(region)
      @client = BunnyStorageClient.new(access_key, api_key, storage_zone, region)

      if cdn
        @base_url = cdn
      else
        @base_url = "https://#{storage_zone}.b-cdn.net"
      end
    end

    def upload(key, io, checksum: nil, filename: nil, content_type: nil, disposition: nil, custom_metadata: {}, **)
      instrument :upload, key: key, checksum: checksum do
        content_disposition = content_disposition_with(filename: filename, type: disposition) if disposition && filename
        upload_with_single_part key, io, checksum: checksum, content_type: content_type, content_disposition: content_disposition, custom_metadata: custom_metadata
      end
    end

    def download(key, &block)
      if block_given?
        instrument :streaming_download, { key: key } do
          stream(key, &block)
        end
      else
        instrument :download, key: key do
          io = StringIO.new object_for(key).get_file

          io.set_encoding(Encoding::BINARY)
        end
      end
    end

    def delete(key)
      instrument :delete, key: key do
        object_for(key).delete_file
      end
    end

    def delete_prefixed(prefix)
      delete prefix
      # instrument :delete_prefixed, prefix: prefix do
      #   # BunnyStorageClient does not natively support this operation yet.
      # end
    end

    def exist?(key)
      instrument :exist, key: key do |payload|
        answer = object_for(key).exist?
        payload[:exist] = answer
        answer
      end
    end

    def url(key, expires_in:, disposition:, filename:, **options)
      instrument :url, {key: key} do |payload|
        url = public_url key
        payload[:url] = url

        url
      end
    end

    def url_for_direct_upload(key, expires_in:, content_type:, content_length:, checksum:, custom_metadata: {})
      instrument :url, key: key do |payload|
        generated_url = storage_api_url(key)

        payload[:url] = generated_url

        generated_url
      end
    end

    def headers_for_direct_upload(key, content_type:, checksum:, filename: nil, disposition: nil, custom_metadata: {}, **)
      {
        'AccessKey' => access_key,
        'Content-Type' => content_type,
        **custom_metadata_headers(custom_metadata)
      }.compact
    end

    def download_chunk(key, range:, **)
      instrument :download_chunk, key: key, range: range do
        data = object_for(key).get_file
        range ? data.byteslice(range) : data
      end
    end

    private

    def blank_to_nil(value)
      return nil if value.nil?
      return nil if value.respond_to?(:strip) && value.strip.empty?
      return nil if value.respond_to?(:empty?) && value.empty?

      value
    end

    def private_url(key, expires_in:, filename:, disposition:, content_type:, **)
      # BunnyStorageClient does not natively support this operation yet.
      public_url(key)
    end

    def public_url(key)
      "#{base_url.to_s.sub(%r{/*$}, '')}/#{key}"
    end

    def upload_with_single_part(key, io, checksum: nil, content_type: nil, content_disposition: nil, custom_metadata: {})
      object_for(key).upload_file(body: io)
      object_for(key).purge_cache
    rescue StandardError
      raise ActiveStorage::IntegrityError
    end

    def stream(key, options = {}, &block)
      io = StringIO.new object_for(key).get_file
      io.set_encoding(Encoding::BINARY)

      chunk_size = 5.megabytes

      while chunk = io.read(chunk_size)
        yield chunk
      end
    end

    def object_for(key)
      client.object(key)
    end

    def custom_metadata_headers(_metadata)
      {}
    end

    def storage_api_url(key)
      "https://#{storage_api_host}/#{storage_zone}/#{escaped_key(key)}"
    end

    def storage_api_host
      region ? "#{region}.storage.bunnycdn.com" : 'storage.bunnycdn.com'
    end

    def escaped_key(key)
      key.split('/').map { |part| CGI.escape(part) }.join('/')
    end
  end
end
