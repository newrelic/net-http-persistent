require 'net/http'
require 'net/http/faster'
require 'uri'

##
# Persistent connections for Net::HTTP
#
# Net::HTTP::Persistent maintains persistent connections across all the
# servers you wish to talk to.  For each host:port you communicate with a
# single persistent connection is created.
#
# Multiple Net::HTTP::Persistent objects will share the same set of
# connections.
#
# Example:
#
#   uri = URI.parse 'http://example.com/awesome/web/service'
#   http = Net::HTTP::Persistent
#   stuff = http.request uri # performs a GET
#
#   # perform a POST
#   post_uri = uri + 'create'
#   post = Net::HTTP::Post.new uri.path
#   post.set_form_data 'some' => 'cool data'
#   http.request post_uri, post # URI is always required

class Net::HTTP::Persistent

  ##
  # The version of Net::HTTP::Persistent use are using

  VERSION = '1.0.1'

  ##
  # Error class for errors raised by Net::HTTP::Persistent.  Various
  # SystemCallErrors are re-raised with a human-readable message under this
  # class.

  class Error < StandardError; end

  ##
  # This client's OpenSSL::X509::Certificate

  attr_accessor :certificate

  ##
  # An SSL certificate authority.  Setting this will set verify_mode to
  # VERIFY_PEER.

  attr_accessor :ca_file

  ##
  # Where this instance's connections live in the thread local variables

  attr_reader :connection_key # :nodoc:

  ##
  # Sends debug_output to this IO via Net::HTTP#set_debug_output.
  #
  # Never use this method in production code, it causes a serious security
  # hole.

  attr_accessor :debug_output

  ##
  # Headers that are added to every request

  attr_reader :headers

  ##
  # The value sent in the Keep-Alive header.  Defaults to 30 seconds

  attr_accessor :keep_alive

  ##
  # A name for this connection.  Allows you to keep your connections apart
  # from everybody else's.

  attr_reader :name

  ##
  # This client's SSL private key

  attr_accessor :private_key

  ##
  # The URL through which requests will be proxied

  attr_reader :proxy_uri

  ##
  # Where this instance's request counts live in the thread local variables

  attr_reader :request_key # :nodoc:

  ##
  # SSL verification callback.  Used when ca_file is set.

  attr_accessor :verify_callback

  ##
  # HTTPS verify mode.  Set to OpenSSL::SSL::VERIFY_NONE to ignore certificate
  # problems.
  #
  # You can use +verify_mode+ to override any default values.

  attr_accessor :verify_mode

  ##
  # Creates a new Net::HTTP::Persistent.
  #
  # Set +name+ to keep your connections apart from everybody else's.  Not
  # required currently, but highly recommended.  Your library name should be
  # good enough.
  #
  # +proxy+ may be set to a URI::HTTP or :ENV to pick up proxy options from
  # the environment.  See proxy_from_env for details.

  def initialize name = nil, proxy = nil
    @name = name

    @proxy_uri = case proxy
                 when :ENV      then proxy_from_env
                 when URI::HTTP then proxy
                 when nil       then # ignore
                 else raise ArgumentError, 'proxy must be :ENV or a URI::HTTP'
                 end

    if @proxy_uri then
      @proxy_args = [
        @proxy_uri.host,
        @proxy_uri.port,
        @proxy_uri.user,
        @proxy_uri.password,
      ]

      @proxy_connection_id = [nil, *@proxy_args].join ':'
    end

    @debug_output = nil
    @headers      = {}
    @keep_alive   = 30

    key = ['net_http_persistent', name, 'connections'].compact.join '_'
    @connection_key = key.intern
    key = ['net_http_persistent', name, 'requests'].compact.join '_'
    @request_key    = key.intern

    @certificate     = nil
    @ca_file         = nil
    @private_key     = nil
    @verify_callback = nil
    @verify_mode     = nil
  end

  ##
  # Creates a new connection for +uri+

  def connection_for uri
    Thread.current[@connection_key] ||= {}
    connections = Thread.current[@connection_key]

    net_http_args = [uri.host, uri.port]
    connection_id = net_http_args.join ':'

    if @proxy_uri then
      connection_id << @proxy_connection_id
      net_http_args.concat @proxy_args
    end

    connections[connection_id] ||= Net::HTTP.new(*net_http_args)
    connection = connections[connection_id]

    unless connection.started? then
      connection.set_debug_output @debug_output if @debug_output

      ssl connection if uri.scheme == 'https'

      connection.start
    end

    connection
  rescue Errno::ECONNREFUSED
    raise Error, "connection refused: #{connection.address}:#{connection.port}"
  end

  ##
  # Returns an error message containing the number of requests performed on
  # this connection

  def error_message connection
    requests =
      Thread.current[@request_key][connection.object_id]

    "after #{requests} requests on #{connection.object_id}"
  end

  ##
  # URI::escape wrapper

  def escape str
    URI.escape str if str
  end

  ##
  # Adds "http://" to the String +uri+ if it is missing.

  def normalize_uri uri
    (uri =~ /^https?:/) ? uri : "http://#{uri}"
  end

  ##
  # Creates a URI for an HTTP proxy server from ENV variables.
  #
  # If +HTTP_PROXY+ is set a proxy will be returned.
  #
  # If +HTTP_PROXY_USER+ or +HTTP_PROXY_PASS+ are set the URI is given the
  # indicated user and password unless HTTP_PROXY contains either of these in
  # the URI.
  #
  # For Windows users lowercase ENV variables are preferred over uppercase ENV
  # variables.

  def proxy_from_env
    env_proxy = ENV['http_proxy'] || ENV['HTTP_PROXY']

    return nil if env_proxy.nil? or env_proxy.empty?

    uri = URI.parse normalize_uri env_proxy

    unless uri.user or uri.password then
      uri.user     = escape ENV['http_proxy_user'] || ENV['HTTP_PROXY_USER']
      uri.password = escape ENV['http_proxy_pass'] || ENV['HTTP_PROXY_PASS']
    end

    uri
  end

  ##
  # Finishes then restarts the Net::HTTP +connection+

  def reset connection
    Thread.current[@request_key].delete connection.object_id

    begin
      connection.finish
    rescue IOError
    end

    connection.start
  rescue Errno::ECONNREFUSED
    raise Error, "connection refused: #{connection.address}:#{connection.port}"
  rescue Errno::EHOSTDOWN
    raise Error, "host down: #{connection.address}:#{connection.port}"
  end

  ##
  # Makes a request on +uri+.  If +req+ is nil a Net::HTTP::Get is performed
  # against +uri+.
  #
  # +req+ must be a Net::HTTPRequest subclass (see Net::HTTP for a list).

  def request uri, req = nil
    Thread.current[@request_key] ||= Hash.new 0
    retried      = false
    bad_response = false

    req = Net::HTTP::Get.new uri.request_uri unless req

    headers.each do |pair|
      req.add_field(*pair)
    end

    req.add_field 'Connection', 'keep-alive'
    req.add_field 'Keep-Alive', @keep_alive

    connection = connection_for uri
    connection_id = connection.object_id

    begin
      count = Thread.current[@request_key][connection_id] += 1
      response = connection.request req

    rescue Net::HTTPBadResponse => e
      message = error_message connection

      reset connection

      raise Error, "too many bad responses #{message}" if bad_response

      bad_response = true
      retry
    rescue IOError, EOFError, Timeout::Error,
           Errno::ECONNABORTED, Errno::ECONNRESET, Errno::EPIPE => e
      due_to = "(due to #{e.message} - #{e.class})"
      message = error_message connection

      reset connection

      raise Error, "too many connection resets #{due_to} #{message}" if retried

      retried = true
      retry
    end

    response
  end

  ##
  # Shuts down all connections in this thread.
  #
  # If you've used Net::HTTP::Persistent across multiple threads you must call
  # this in each thread.

  def shutdown
    Thread.current[@connection_key].each do |_, connection|
      connection.finish
    end

    Thread.current[@connection_key] = nil
    Thread.current[@request_key]    = nil
  end

  ##
  # Enables SSL on +connection+

  def ssl connection
    require 'net/https'
    connection.use_ssl = true

    if @ca_file then
      connection.ca_file = @ca_file
      connection.verify_mode = OpenSSL::SSL::VERIFY_PEER
      connection.verify_callback = @verify_callback if @verify_callback
    end

    if @certificate and @private_key then
      connection.cert = @certificate
      connection.key  = @private_key
    end

    connection.verify_mode = @verify_mode if @verify_mode
  end

end
