module Agents
  class BybitAgent < Agent
    include FormConfigurable
    can_dry_run!
    no_bulk_receive!
    default_schedule 'every_1h'

    description <<-MD
      The Bybit Agent interacts with the Bybit API and can create events / tasks if wanted / needed.

      The `type` can be like checking the wallet's balance, alerts.

      `apikey` is needed for auth endpoint.

      `secretkey` is needed for auth endpoint.

      `windows` to specify how long an HTTP request is valid.

      `limit` to timit for data size.

      `debug` is for adding verbosity.

      `expected_receive_period_in_days` is used to determine if the Agent is working. Set it to the maximum number of days
      that you anticipate passing without this Agent receiving an incoming Event.
    MD

    event_description <<-MD
      Events look like this:

          {
            "retCode": 0,
            "retMsg": "OK",
            "result": {
              "balances": [
                {
                  "coin": "ADA",
                  "coinId": "ADA",
                  "total": "500000000000",
                  "free": "500000000000",
                  "locked": "0"
                }
              ]
            },
            "retExtInfo": {},
            "time": 1676117370511
          }
    MD

    def default_options
      {
        'type' => '',
        'apikey' => '',
        'windows' => '5000',
        'limit' => '10',
        'secretkey' => '',
        'debug' => 'false',
        'expected_receive_period_in_days' => '2',
        'changes_only' => 'true'
      }
    end

    form_configurable :debug, type: :boolean
    form_configurable :apikey, type: :string
    form_configurable :secretkey, type: :string
    form_configurable :limit, type: :string
    form_configurable :windows, type: :string
    form_configurable :expected_receive_period_in_days, type: :string
    form_configurable :changes_only, type: :boolean
    form_configurable :type, type: :array, values: ['get_balances', 'order_history', 'trade_history']
    def validate_options
      errors.add(:base, "type has invalid value: should be 'get_balances' 'order_history' 'trade_history'") if interpolated['type'].present? && !%w(get_balances order_history trade_history).include?(interpolated['type'])

      unless options['apikey'].present? || !['get_balances', 'order_history', 'trade_history'].include?(options['type'])
        errors.add(:base, "apikey is a required field")
      end

      unless options['secretkey'].present? || !['get_balances', 'order_history', 'trade_history'].include?(options['type'])
        errors.add(:base, "secretkey is a required field")
      end

      unless options['limit'].present? || !['order_history', 'trade_history'].include?(options['type'])
        errors.add(:base, "limit is a required field")
      end

      if options.has_key?('changes_only') && boolify(options['changes_only']).nil?
        errors.add(:base, "if provided, changes_only must be true or false")
      end

      if options.has_key?('debug') && boolify(options['debug']).nil?
        errors.add(:base, "if provided, debug must be true or false")
      end

      unless options['expected_receive_period_in_days'].present? && options['expected_receive_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_receive_period_in_days' to indicate how many days can pass before this Agent is considered to be not working")
      end
    end

    def working?
      event_created_within?(options['expected_receive_period_in_days']) && !recent_error_logs?
    end

    def check
      trigger_action
    end

    private


    def new_nonce
      (Time.now.to_f * 1000000).floor.to_s
    end

    def log_curl_output(code,body)

      log "request status : #{code}"

      if interpolated['debug'] == 'true'
        log "body"
        log body
      end

    end

    def genSignature(payload,time_stamp)
        param_str = time_stamp + interpolated['apikey'] + interpolated['windows'] + payload
      if interpolated['debug'] == 'true'
        log "param_str"
        log param_str
      end
        OpenSSL::HMAC.hexdigest('sha256', interpolated['secretkey'], param_str)
    end

    def trade_history(base_url)

      time_stamp = DateTime.now.strftime('%Q')
      endPoint = "/spot/v3/private/my-trades"
      tradeLinkId = SecureRandom.uuid
      payload = "tradeLinkId=" + tradeLinkId + '&limit' + interpolated['limit']
      signature = genSignature(payload,time_stamp)
      payload="?"+payload

      if interpolated['debug'] == 'true'
        log "signature"
        log signature
      end
      fullUrl = base_url + endPoint + payload
      uri = URI.parse(fullUrl)
      request = Net::HTTP::Get.new(uri)
      request["X-BAPI-SIGN"] = signature
      request["X-BAPI-API-KEY"] = interpolated['apikey']
      request["X-BAPI-TIMESTAMP"] = time_stamp
      request["X-BAPI-RECV-WINDOW"] = interpolated['windows']

      req_options = {
        use_ssl: uri.scheme == "https",
      }

      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      log_curl_output(response.code,response.body)

      payload = JSON.parse(response.body)
      if interpolated['changes_only'] == 'true'
        if payload.to_s != memory['last_status']
          if "#{memory['last_status']}" == ''
            payload['result']['list'].each do | trade |
              create_event :payload => trade
            end
          else
            last_status = memory['last_status'].gsub("=>", ": ").gsub(": nil,", ": null,")
            last_status = JSON.parse(last_status)
            payload['result']['list'].each do | trade |
              found = false
              last_status['result']['list'].each do | tradebis |
                if trade == tradebis
                  found = true
                end
              end
              if interpolated['debug'] == 'true'
                log found
              end
              if found == false
                create_event :payload => trade
              end
            end
          end
          memory['last_status'] = payload.to_s
        end
      else
        create_event payload: payload
        if payload.to_s != memory['last_status']
          memory['last_status'] = payload.to_s
        end
      end
    end

    def order_history(base_url)

      time_stamp = DateTime.now.strftime('%Q')
      endPoint = "/v5/order/history"
      orderLinkId = SecureRandom.uuid
      payload = "orderLinkId=" + orderLinkId + '&limit' + interpolated['limit'] + '&category=spot'
      signature = genSignature(payload,time_stamp)
      payload="?"+payload
    
      if interpolated['debug'] == 'true'
        log "signature"
        log signature
      end
      fullUrl = base_url + endPoint + payload
      uri = URI.parse(fullUrl)
      request = Net::HTTP::Get.new(uri)
      request["X-BAPI-SIGN"] = signature
      request["X-BAPI-API-KEY"] = interpolated['apikey']
      request["X-BAPI-TIMESTAMP"] = time_stamp
      request["X-BAPI-RECV-WINDOW"] = interpolated['windows']
    
      req_options = {
        use_ssl: uri.scheme == "https",
      }

      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      log_curl_output(response.code,response.body)

      payload = JSON.parse(response.body)
      if interpolated['changes_only'] == 'true'
        if payload != memory['last_status']
          payload['result']['list'].each do | order |
            found = false
            if interpolated['debug'] == 'true'
              log "order"
              log order
            end
            if !memory['last_status'].nil? and memory['last_status'].present?
              if interpolated['debug'] == 'true'
                log "memory"
                log memory['last_status']
              end
              last_status = memory['last_status']
              last_status['result']['list'].each do |orderbis|
                if order['id'] == orderbis['id']
                  found = true
                end
                if interpolated['debug'] == 'true'
                  log "orderbis"
                  log orderbis
                  log "found is #{found}!"
                end
              end
            end
            if found == false
              create_event payload: order
            end
          end
        else
          if interpolated['debug'] == 'true'
            log "nothing to compare"
          end
        end
      else
        create_event payload: payload
        if payload != memory['last_status']
        end
      end
      memory['last_status'] = payload
    end

    def get_balances(base_url)

      time_stamp = DateTime.now.strftime('%Q')
      endPoint = "/v5/account/wallet-balance"
      orderLinkId = SecureRandom.uuid
      payload = "accountType=UNIFIED" 
      signature = genSignature(payload,time_stamp)
      payload="?"+payload
    
      if interpolated['debug'] == 'true'
        log "signature"
        log signature
      end
      fullUrl = base_url + endPoint + payload
      uri = URI.parse(fullUrl)
      request = Net::HTTP::Get.new(uri)
      request["X-BAPI-SIGN"] = signature
      request["X-BAPI-API-KEY"] = interpolated['apikey']
      request["X-BAPI-TIMESTAMP"] = time_stamp 
      request["X-BAPI-RECV-WINDOW"] = interpolated['windows']
    
      req_options = {
        use_ssl: uri.scheme == "https",
      }

      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      log_curl_output(response.code,response.body)

      payload = JSON.parse(response.body)
      if interpolated['changes_only'] == 'true'
        if payload != memory['last_status']
          payload['result']['list'][0]['coin'].each do | coin |
            found = false
            if interpolated['debug'] == 'true'
              log "coin"
              log coin
            end
            if !memory['last_status'].nil? and memory['last_status'].present?
              if interpolated['debug'] == 'true'
                log "memory"
                log memory['last_status']
              end
              last_status = memory['last_status']
              last_status['result']['list'][0]['coin'].each do |coinbis|
                if coin['id'] == coinbis['id']
                  found = true
                end
                if interpolated['debug'] == 'true'
                  log "coinbis"
                  log coinbis
                  log "found is #{found}!"
                end
              end
            end
            if found == false
              create_event payload: coin
            end
          end
        else
          if interpolated['debug'] == 'true'
            log "nothing to compare"
          end
        end
      else
        create_event payload: payload
        if payload != memory['last_status']
        end
      end
      memory['last_status'] = payload
    end

    def trigger_action()

      base_url = 'https://api.bybit.com'
      case interpolated['type']
      when "get_balances"
        get_balances(base_url)
      when "order_history"
        order_history(base_url)
      when "trade_history"
        trade_history(base_url)
      else
        log "Error: type has an invalid value (#{type})"
      end
    end
  end
end
