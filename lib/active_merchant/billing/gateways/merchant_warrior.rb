require 'digest/md5'
require 'rexml/document'

module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class MerchantWarriorGateway < Gateway
      TOKEN_TEST_URL = 'https://base.merchantwarrior.com/token/'
      TOKEN_LIVE_URL = 'https://api.merchantwarrior.com/token/'

      POST_TEST_URL = 'https://base.merchantwarrior.com/post/'
      POST_LIVE_URL = 'https://api.merchantwarrior.com/post/'

      self.supported_countries = ['AU']
      self.supported_cardtypes = %i[visa master american_express
                                    diners_club discover jcb]
      self.homepage_url = 'https://www.merchantwarrior.com/'
      self.display_name = 'Merchant Warrior'

      self.money_format = :dollars
      self.default_currency = 'AUD'

      def initialize(options = {})
        requires!(options, :merchant_uuid, :api_key, :api_passphrase)
        super
      end

      def authorize(money, payment_method, options = {})
        post = {}
        add_amount(post, money, options)
        add_order_id(post, options)
        add_address(post, options)
        add_payment_method(post, payment_method)
        add_recurring_flag(post, options)
        add_soft_descriptors(post, options)
        add_three_ds(post, options)
        post['storeID'] = options[:store_id] if options[:store_id]
        commit('processAuth', post)
      end

      def purchase(money, payment_method, options = {})
        post = {}
        add_amount(post, money, options)
        add_order_id(post, options)
        add_address(post, options)
        add_payment_method(post, payment_method)
        add_recurring_flag(post, options)
        add_soft_descriptors(post, options)
        add_three_ds(post, options)
        post['storeID'] = options[:store_id] if options[:store_id]
        commit('processCard', post)
      end

      def capture(money, identification, options = {})
        post = {}
        add_amount(post, money, options)
        add_transaction(post, identification)
        add_soft_descriptors(post, options)
        post['captureAmount'] = amount(money)
        commit('processCapture', post)
      end

      def refund(money, identification, options = {})
        post = {}
        add_amount(post, money, options)
        add_transaction(post, identification)
        add_soft_descriptors(post, options)
        post['refundAmount'] = amount(money)
        commit('refundCard', post)
      end

      def void(identification, options = {})
        post = {}
        # The amount parameter is required for void transactions
        # on the Merchant Warrior gateway.
        post['transactionAmount'] = options[:amount]
        post['hash'] = void_verification_hash(identification)
        add_transaction(post, identification)
        commit('processVoid', post)
      end

      def store(creditcard, options = {})
        post = {
          'cardName' => scrub_name(creditcard.name),
          'cardNumber' => creditcard.number,
          'cardExpiryMonth' => format(creditcard.month, :two_digits),
          'cardExpiryYear'  => format(creditcard.year, :two_digits)
        }
        commit('addCard', post)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((&?paymentCardNumber=)[^&]*)i, '\1[FILTERED]').
          gsub(%r((CardNumber=)[^&]*)i, '\1[FILTERED]').
          gsub(%r((&?paymentCardCSC=)[^&]*)i, '\1[FILTERED]').
          gsub(%r((&?apiKey=)[^&]*)i, '\1[FILTERED]')
      end

      private

      def add_transaction(post, identification)
        post['transactionID'] = identification
      end

      def add_address(post, options)
        return unless (address = (options[:billing_address] || options[:address]))

        post['customerName'] = scrub_name(address[:name])
        post['customerCountry'] = address[:country]
        post['customerState'] = address[:state] || 'N/A'
        post['customerCity'] = address[:city]
        post['customerAddress'] = address[:address1]
        post['customerPostCode'] = address[:zip]
        post['customerIP'] = address[:ip] || options[:ip]
        post['customerPhone'] = address[:phone] || address[:phone_number]
        post['customerEmail'] = address[:email] || options[:email]
      end

      def add_order_id(post, options)
        post['transactionProduct'] = truncate(options[:order_id], 34) || SecureRandom.hex(15)
      end

      def add_payment_method(post, payment_method)
        if payment_method.respond_to?(:number)
          add_creditcard(post, payment_method)
        else
          add_token(post, payment_method)
        end
      end

      def add_token(post, token)
        post['cardID'] = token
      end

      def add_creditcard(post, creditcard)
        post['paymentCardNumber'] = creditcard.number
        post['paymentCardName'] = scrub_name(creditcard.name)
        post['paymentCardExpiry'] = creditcard.expiry_date.expiration.strftime('%m%y')
        post['paymentCardCSC'] = creditcard.verification_value if creditcard.verification_value?
      end

      def scrub_name(name)
        name.gsub(/[^a-zA-Z\. -]/, '')
      end

      def add_amount(post, money, options)
        currency = (options[:currency] || currency(money))

        post['transactionAmount'] = amount(money)
        post['transactionCurrency'] = currency
        post['hash'] = verification_hash(amount(money), currency)
      end

      def add_recurring_flag(post, options)
        return if options[:recurring_flag].nil?

        post['recurringFlag'] = options[:recurring_flag]
      end

      def add_soft_descriptors(post, options)
        post['descriptorName'] = options[:descriptor_name] if options[:descriptor_name]
        post['descriptorCity'] = options[:descriptor_city] if options[:descriptor_city]
        post['descriptorState'] = options[:descriptor_state] if options[:descriptor_state]
      end

      def verification_hash(money, currency)
        Digest::MD5.hexdigest(
          (
            @options[:api_passphrase].to_s +
            @options[:merchant_uuid].to_s +
            money.to_s +
            currency
          ).downcase
        )
      end

      def void_verification_hash(transaction_id)
        Digest::MD5.hexdigest(
          (
            @options[:api_passphrase].to_s +
            @options[:merchant_uuid].to_s +
            transaction_id
          ).downcase
        )
      end

      def add_three_ds(post, options)
        return unless three_d_secure = options[:three_d_secure]

        post.merge!({
          threeDSEci: three_d_secure[:eci],
          threeDSXid: three_d_secure[:xid] || three_d_secure[:ds_transaction_id],
          threeDSCavv: three_d_secure[:cavv],
          threeDSStatus: three_d_secure[:authentication_response_status],
          threeDSV2Version: three_d_secure[:version]
        }.compact)
      end

      def parse(body)
        xml = REXML::Document.new(body)

        return { response_message: 'Invalid gateway response' } unless xml.root.present?

        response = {}
        xml.root.elements.to_a.each do |node|
          parse_element(response, node)
        end
        response
      end

      def parse_element(response, node)
        if node.has_elements?
          node.elements.each { |element| parse_element(response, element) }
        else
          response[node.name.underscore.to_sym] = node.text
        end
      end

      def commit(action, post)
        add_auth(action, post)

        response = parse(ssl_post(url_for(action, post), post_data(post)))

        Response.new(
          success?(response),
          response[:response_message],
          response,
          test: test?,
          authorization: (response[:card_id] || response[:transaction_id])
        )
      end

      def add_auth(action, post)
        post['merchantUUID'] = @options[:merchant_uuid]
        post['apiKey'] = @options[:api_key]
        post['method'] = action unless token?(post)
      end

      def url_for(action, post)
        if token?(post)
          [(test? ? TOKEN_TEST_URL : TOKEN_LIVE_URL), action].join('/')
        else
          (test? ? POST_TEST_URL : POST_LIVE_URL)
        end
      end

      def token?(post)
        (post['cardID'] || post['cardName'])
      end

      def success?(response)
        (response[:response_code] == '0')
      end

      def post_data(post)
        post.collect { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
      end
    end
  end
end
