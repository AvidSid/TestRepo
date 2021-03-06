require 'sinatra'
require 'logger'
require 'json'
require 'openssl'
require 'octokit'
require 'jwt'
require 'base64'
require 'fileutils'
require 'time' # This is necessary to get the ISO 8601 representation of a Time object
require 'rest-client'

set :port, 3333

#
#
# This is a boilerplate server for your own GitHub App. You can read more about GitHub Apps here:
# https://developer.github.com/apps/
#
# On its own, this app does absolutely nothing, except that it can be installed.
# It's up to you to add fun functionality!
# You can check out one example in advanced_server.rb.
#
# This code is a Sinatra app, for two reasons.
# First, because the app will require a landing page for installation.
# Second, in anticipation that you will want to receive events over a webhook from GitHub, and respond to those
# in some way. Of course, not all apps need to receive and process events! Feel free to rip out the event handling
# code if you don't need it.
#
# Have fun! Please reach out to us if you have any questions, or just to show off what you've built!
#

class GHAapp < Sinatra::Application

# Never, ever, hardcode app tokens or other secrets in your code!
# Always extract from a runtime source, like an environment variable.


# Notice that the private key must be in PEM format, but the newlines should be stripped and replaced with
# the literal `\n`. This can be done in the terminal as such:
# export GITHUB_PRIVATE_KEY=`awk '{printf "%s\\n", $0}' private-key.pem`
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n")) # convert newlines

# You set the webhook secret when you create your app. This verifies that the webhook is really coming from GH.
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']

# Get the app identifier—an integer—from your app page after you create your app. This isn't actually a secret,
# but it is something easier to configure at runtime.
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']


########## Configure Sinatra
#
# Let's turn on verbose logging during development
#
  configure :development do
    set :logging, Logger::DEBUG
  end


########## Before each request to our app
#
# Before each request to our app, we want to instantiate an Octokit client. Doing so requires that we construct a JWT.
# https://jwt.io/introduction/
# We have to also sign that JWT with our private key, so GitHub can be sure that
#  a) it came from us
#  b) it hasn't been altered by a malicious third party
#
  before do
    payload = {
        # The time that this JWT was issued, _i.e._ now.
        iat: Time.now.to_i,

        # How long is the JWT good for (in seconds)?
        # Let's say it can be used for 10 minutes before it needs to be refreshed.
        # TODO we don't actually cache this token, we regenerate a new one every time!
        exp: Time.now.to_i + (3 * 60),

        # Your GitHub App's identifier number, so GitHub knows who issued the JWT, and know what permissions
        # this token has.
        iss: APP_IDENTIFIER
    }

    # Cryptographically sign the JWT
    jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

    # Create the Octokit client, using the JWT as the auth token.
    # Notice that this client will _not_ have sufficient permissions to do many interesting things!
    # We might, for particular endpoints, need to generate an installation token (using the JWT), and instantiate
    # a new client object. But we'll cross that bridge when/if we get there!
    @client ||= Octokit::Client.new(bearer_token: jwt)
  end




########## Events
#
# This is the webhook endpoint that GH will call with events, and hence where we will do our event handling
#

  post '/' do
    request.body.rewind
    payload_raw = request.body.read # We need the raw text of the body to check the webhook signature
    begin
      payload = JSON.parse payload_raw
    rescue
      payload = {}
    end

    # Check X-Hub-Signature to confirm that this webhook was generated by GitHub, and not a malicious third party.
    # The way this works is: We have registered with GitHub a secret, and we have stored it locally in WEBHOOK_SECRET.
    # GitHub will cryptographically sign the request payload with this secret. We will do the same, and if the results
    # match, then we know that the request is from GitHub (or, at least, from someone who knows the secret!)
    # If they don't match, this request is an attack, and we should reject it.
    # The signature comes in with header x-hub-signature, and looks like "sha1=123456"
    # We should take the left hand side as the signature method, and the right hand side as the
    # HMAC digest (the signature) itself.
    their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
    method, their_digest = their_signature_header.split('=')
    our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, payload_raw)
    halt 401 unless their_digest == our_digest

    # Determine what kind of event this is, and take action as appropriate
    # TODO we assume that GitHub will always provide an X-GITHUB-EVENT header in this case, which is a reasonable
    #      assumption, however we should probably be more careful!
    logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
    logger.debug "----         action #{payload['action']}" unless payload['action'].nil?

    case request.env['HTTP_X_GITHUB_EVENT']
    when 'issues'
      # Add code here to handle the event that you care about!
      authenticate_installation(payload)
      if payload['action'] === 'opened'
        handle_issue_opened_event(payload)

      end
    when 'push'

      authenticate_installation(payload)
      handle_push_event(payload)
      end

    'ok'  # we have to return _something_ ;)
  end


########## Helpers
#
# These functions are going to help us do some tasks that we don't want clogging up the happy paths above, or
# that need to be done repeatedly. You can add anything you like here, really!
#

  helpers do

    # This is our handler for the event that you care about! Of course, you'll want to change the name to reflect
    # the actual event name! But this is where you will add code to process the event.
    def handle_issue_opened_event(payload)
      logger.debug 'An issue was opened'
      logger.debug payload

      repo = payload['repository']['full_name']
      issue_number = payload['issue']['number']
      @bot_client.add_labels_to_an_issue(repo, issue_number, ['needs-response'])
    end

    def handle_push_event(payload)
      logger.debug 'A push event was received'
      logger.debug payload

      repo = payload['repository']['full_name']

      repo_url = payload['repository']['clone_url']

      author_name = payload['commits'][0]['author']['name']

      author_email = payload['commits'][0]['author']['email']

      branch_ref = payload['ref']

      branch = branch_ref.split('/').last

      post_commit_hash = payload['after']

      logger.debug repo

      logger.debug repo_url

      logger.debug author_name

      logger.debug author_email

      logger.debug branch

      $files_to_upload_array = Array.new

      repo = payload['repository']['full_name']

      result = @bot_client.contents(repo, {})

      temp_folder_name = 'temp-' + post_commit_hash

      recursive_repo_file_fetch(result, repo, '', temp_folder_name)

      logger.debug $files_to_upload_array

      post_to_server(repo_url, branch, author_name, author_email, '9dc27a01-ce32-45df-9c0f-c39254a40b2c', temp_folder_name)

    end

    def recursive_repo_file_fetch(result, repo, base_path, temp_folder_name)

      result.each { |item|

        item_name = item.name
        # logger.debug item_name

        case item.type
        when 'file'
          # logger.debug 'item is of type file'

          if (item_name.end_with? '.tf') or (item_name.end_with? '.tf.json')
            logger.debug 'item is a terraform config'
            logger.debug item_name
            logger.debug item.download_url
            path_for_fetch_file = item_name
            if base_path != ''
              path_for_fetch_file = base_path + "/" + item_name
            end
            content_file = @bot_client.contents(repo, :path => path_for_fetch_file)
            file_data = Base64.decode64(content_file.content)
            path = temp_folder_name + "/" + path_for_fetch_file
            make_directories_if_needed(path)
            File.write(path, file_data)
            $files_to_upload_array << path
          end

          # if item_name.ends_with? '.tf.json'
          #   logger.debug 'item is of type TF JSON'

          # end

        when 'dir'
          # logger.debug "item is of type directory"

          path_for_fetch = item_name

          if base_path != ''
            path_for_fetch = base_path + "/" + item_name
          end

          # logger.debug "path : " + path_for_fetch
          dir_result = @bot_client.contents(repo, :path => path_for_fetch)
          recursive_repo_file_fetch(dir_result, repo, path_for_fetch, temp_folder_name)
        end
      }
    end

    def make_directories_if_needed(file_path)
      dirname = File.dirname(file_path)
      unless File.directory?(dirname)
        FileUtils.mkdir_p(dirname)
      end
    end

    ## method to authenticate and set up the client go
    def authenticate_installation(payload)
      installation_id = payload['installation']['id']
      installation_token = @client.create_app_installation_access_token(installation_id)[:token]
      @bot_client ||= Octokit::Client.new(bearer_token: installation_token)
    end

    def post_to_server(repo_url, branch, author_name, author_email, customer_id, temp_folder_name)
      url = "http://localhost:8080/public/terraform/githubFileUpload"

      output = system('curl "http://localhost:8080/public/terraform/githubFileUpload" -F "customerID='+ customer_id + '" -F "repoURL=' + repo_url + '" -F "authorName=' + author_name + '" -F "authorEmail=' + author_email + '" -F "branch='+ branch +'" `find ' + temp_folder_name + ' \( -name "*.tf" -o -name "*.tf.json" \) -type f -exec echo "-F files=@{}" \;`')
      puts "output is #{output}"

      #to delete the created temp files
      FileUtils.rm_rf(temp_folder_name + "/", secure: true)

      # @file_array = Array.new

      # $files_to_upload_array.each { |file_location|
      #   @file_array.push(File.new(file_location, 'rb'))
      # }

      # params = []

      # $files_to_upload_array.each { |file_location|
      #   params << [:files, File.new(file_location, 'rb')]
      # }
      # logger.debug 'adding new files: ' + params
      # params = {
      #   :customerID => customer_id,
      #   :repoURL => repo_url,
      #   :branch => branch,
      #   :authorName => author_name,
      #   :authorEmail => author_email,

      #   :multipart => true
      # }

      # logger.debug params.count

      # RestClient.post(url,{
      #   :transfer => {
      #     :customerID => customer_id,
      #     :repoURL => repo_url,
      #     :branch => branch,
      #     :authorName => author_name,
      #     :authorEmail => author_email,
      #   },
      #   :customerID => customer_id,
      #   :repoURL => repo_url,
      #   :branch => branch,
      #   :authorName => author_name,
      #   :authorEmail => author_email,
      #   :upload => params
      # }){ |response, request, result, &block|

      #   case response.code
      #   when 200
      #     logger.debug response
      #   else
      #     response.return!(&block)
      #   end
      # }
    end

  end


# Finally some logic to let us run this server directly from the commandline, or with Rack
# Don't worry too much about this code ;) But, for the curious:
# $0 is the executed file
# __FILE__ is the current file
# If they are the same—that is, we are running this file directly, call the Sinatra run method
  run! if __FILE__ == $0
end
