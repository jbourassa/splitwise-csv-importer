#! /usr/bin/env ruby
# frozen_string_literal: true

require "bundler/inline"
require "fileutils"

gemfile do
  source "https://rubygems.org"
  gem "oauth2"
  gem "dotenv"
  gem "dry-monads"
  gem "httparty"

  gem "pry"
end

Dotenv.load

SplitWiseApp = Struct.new(:key, :secret)

class SplitWiseApiClient
  include HTTParty

  base_uri("https://www.splitwise.com/api/v3.0")
  headers(accept: "application/json")

  def initialize(app:, token:)
    @app = app
    @token = token
  end

  def get_current_user
    @get_current_user ||= get("/get_current_user")
  end

  def create_expense(expense)
    post(
      "/create_expense",
      body: expense,
    )
  end

  def get_expenses(query = {})
    get("/get_expenses", query_string: query)
  end

  def auth?
    !get_current_user.parsed_response.key?("error")
  end

  private

  def get(path, **opts)
    self.class.get(path, merge_headers(opts))
  end

  def post(path, **opts)
    self.class.post(
      path,
      merge_headers(
        opts,
        "Content-Type": "application/x-www-form-urlencoded"
      )
    )
  end

  def merge_headers(opts, **extra)
    headers = opts
      .fetch(:headers, {})
      .merge(Authorization: "Bearer #{@token}")
      .merge(extra)

    opts.merge(headers: headers)
  end
end

class SplitWiseAuth
  include Dry::Monads[:result]

  TOKEN_URL = "https://secure.splitwise.com/oauth/token"
  AUTHORIZE_URL = "https://secure.splitwise.com/oauth/authorize"
  BASE_SITE = "https://secure.splitwise.com/"
  PORT = 15_131
  LOCAL_URL = "http://localhost:#{PORT}"
  CALLBACK_URL = "#{LOCAL_URL}/callback"

  def initialize(app:, logger: Logger.new("/dev/null"))
    @app = app
    @logger = logger
    @oauth_client = OAuth2::Client.new(app.key, app.secret, site: BASE_SITE)
    @server = nil
    @signal_was = nil
  end

  def serve
    require "webrick"
    require "cgi"

    puts "Opening #{LOCAL_URL}"

    @server = WEBrick::HTTPServer.new(
      Port: 15131,
      Logger: @logger,
      AccessLog: @logger,
      StartCallback: -> { `open '#{LOCAL_URL}'` }
    )

    result = nil

    server.mount_proc "/" do |_, res|
      res.set_redirect(
        WEBrick::HTTPStatus::TemporaryRedirect,
        @oauth_client.auth_code.authorize_url(redirect_uri: CALLBACK_URL),
      )
    end

    server.mount_proc "/callback" do |req, res|
      authorization_code = CGI.parse(req.query_string).fetch("code", nil)

      access_token = @oauth_client.auth_code.get_token(
        authorization_code,
        redirect_uri: CALLBACK_URL
      )

      res.body = "OK! Back to the terminal"

      result = Success(access_token.to_hash)

      stop
    end

    @signal_was = trap("INT") do
      stop
      result = Failure("Aborted")
    end

    server.start

    trap("INT", @signal_was)

    result
  end

  private

  attr_reader :server

  def stop
    server.stop
  end
end

class AuthCache
  class << self
    def write(token)
      FileUtils.mkdir_p("tmp")
      File.write(cache_path, token)
    end

    def read
      return unless File.exist?(cache_path)

      File.read(cache_path).chomp
    end

    private

    def cache_path
      "tmp/bearer_token"
    end
  end
end

ExpenseEntry = Struct.new(
  :amount,
  :description,
  :date,
  :comment,
  :split,
  keyword_init: true
) do
  def my_share
    shares.first
  end

  def their_share
    shares.last
  end

  private

  def shares
    @shares ||=
      if split == "n"
        [0, amount]
      else
        half = (amount / 2.0).round(2)
        [half, amount - half].shuffle
      end
  end
end

require "csv"

class ExpenseParser
  class << self
    def parse_file(path)
      CSV.foreach(
        path,
        headers: true,
        converters: :all,
        header_converters: :symbol,
      ).map do |row|
        ExpenseEntry.new(
          amount: row[:amount],
          description: row[:description],
          date: row[:date],
          comment: row[:comment],
          split: row[:split],
        )
      end
    end
  end
end

def main
  app = SplitWiseApp.new(
    ENV.fetch("SW_KEY"),
    ENV.fetch("SW_SECRET"),
  )

  client = SplitWiseApiClient.new(app: app, token: AuthCache.read)

  unless client.auth?
    token = SplitWiseAuth.new(app: app)
      .serve
      .value_or do |error_message|
        puts "\nAuthentication failed"
        puts " #{error_message}"

        return nil
      end
      .fetch(:access_token)

    AuthCache.write(token)
    client = SplitWiseApiClient.new(app: app, token: token)
  end

  expenses = ExpenseParser.parse_file(ENV.fetch("FILENAME"))

  my_user_id = ENV.fetch("MY_USER_ID")
  group_id = ENV.fetch("GROUP_ID")
  friend_user_id = ENV.fetch("FRIEND_USER_ID")

  expenses.each do |expense|
    exp = {
      cost: expense.amount,
      currency_code: "CAD",
      group_id: group_id,
      description: expense.description,

      users__0__user_id: my_user_id,
      users__0__paid_share: expense.amount,
      users__0__owed_share: expense.my_share,

      users__1__user_id: friend_user_id,
      users__1__paid_share: 0,
      users__1__owed_share: expense.their_share,

      creation_method: "equal",
      date: expense.date.to_s
    }

    puts "Creating: #{'%7.2f' % expense.amount}$   #{expense.description}"
    res = client.create_expense(exp)

    unless res.ok?
      puts "Failed to create expense! Let's see what happened..."
      binding.pry
    end
  end
end

main
