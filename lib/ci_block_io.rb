require 'ci_block_io/version'
require 'httpclient'
require 'oj'
require 'ecdsa'
require 'openssl'
require 'digest'
require 'pbkdf2'
require 'securerandom'
require 'base64'

class CiBlockIoWithdrawException < StandardError
end

module CiBlockIo

  @api_key = nil
  @base_url = nil
  @pin = nil
  @encryptionKey = nil
  @client = nil
  @conn_pool = nil
  @version = nil
  @mock_response = {}

  def self.mock(method_name, response)
    @mock_response[method_name.to_s] = response
  end

  def self.set_options(args = {})
    # initialize BlockIo
    @api_key = args[:api_key]
    @pin = args[:pin]

    @encryptionKey = Helper.pinToAesKey(@pin) if !@pin.nil?

    hostname = args[:hostname] || "block.io"
    @base_url = "https://" << hostname << "/api/VERSION/API_CALL/?api_key="

    @client = HTTPClient.new
    @client.tcp_keepalive = true
    @client.ssl_config.ssl_version = :auto

    @version = args[:version] || 2 # default version is 2

    self.api_call(['get_balance',""])
  end

  def self.method_missing(m, *args, &block)      

    method_name = m.to_s

    if ['withdraw', 'withdraw_from_address', 'withdraw_from_addresses', 'withdraw_from_user', 'withdraw_from_users', 'withdraw_from_label', 'withdraw_from_labels'].include?(m.to_s) then
      # need to withdraw from an address
      self.withdraw(args.first, m.to_s)
    elsif ['sweep_from_address'].include?(m.to_s) then
      # need to sweep from an address
      self.sweep(args.first, m.to_s)
    else
      params = get_params(args.first)
      self.api_call([method_name, params])
    end

  end 

  def self.withdraw(args = {}, method_name = 'withdraw')
    # validate arguments for withdrawal of funds TODO

    raise CiBlockIoWithdrawException.new("PIN not set. Use BlockIo.set_options(:api_key=>'API KEY',:pin=>'SECRET PIN',:version=>'API VERSION')") if @pin.nil?

    params = get_params(args)

    params << "&pin=" << @pin if @version == 1 # Block.io handles the Secret PIN in the legacy API (v1)

    response = self.api_call([method_name, params])

    if response['data'].has_key?('reference_id') then
      # Block.io's asking us to provide some client-side signatures, let's get to it

      # extract the passphrase
      encrypted_passphrase = response['data']['encrypted_passphrase']['passphrase']

      # let's get our private key
      key = Helper.extractKey(encrypted_passphrase, @encryptionKey)

      raise CiBlockIoWithdrawException.new('Public key mismatch for requested signer and ourselves. Invalid Secret PIN detected.') if key.public_key != response['data']['encrypted_passphrase']['signer_public_key']

      # let's sign all the inputs we can
      inputs = response['data']['inputs']

      Helper.signData(inputs, [key])

      # the response object is now signed, let's stringify it and finalize this withdrawal
      response = self.api_call(['sign_and_finalize_withdrawal',{:signature_data => Oj.dump(response['data'])}])

      # if we provided all the required signatures, this transaction went through
      # otherwise Block.io responded with data asking for more signatures
      # the latter will be the case for dTrust addresses
    end

    return response

  end

  def self.sweep(args = {}, method_name = 'sweep_from_address')
    # sweep coins from a given address + key

    raise Exception.new("No private_key provided.") unless args.has_key?(:private_key)

    key = Key.from_wif(args[:private_key])

    args[:public_key] = key.public_key # so Block.io can match things up
    args.delete(:private_key) # the key must never leave this machine

    params = get_params(args)

    response = self.api_call([method_name, params])

    if response['data'].has_key?('reference_id') then
      # Block.io's asking us to provide some client-side signatures, let's get to it

      # let's sign all the inputs we can
      inputs = response['data']['inputs']
      Helper.signData(inputs, [key])

      # the response object is now signed, let's stringify it and finalize this withdrawal
      response = self.api_call(['sign_and_finalize_sweep',{:signature_data => Oj.dump(response['data'])}])

      # if we provided all the required signatures, this transaction went through
      # otherwise Block.io responded with data asking for more signatures
      # the latter will be the case for dTrust addresses
    end

    return response

  end


  private

  def self.api_call(endpoint)
    return @mock_response[endpoint[0]] if @mock_response.keys.include?(endpoint[0])

    body = nil
    base_url = @base_url.gsub('API_CALL',endpoint[0]).gsub('VERSION', 'v'+@version.to_s)
    return nil if base_url.nil? || @api_key.nil?

    response = @client.post(base_url + @api_key, endpoint[1])

    begin
      body = Oj.load(response.body)
      return unless body['status'].eql?('success')
      case endpoint[0]
      when 'withdraw'
        raise CiBlockIoWithdrawException.new(body['data']['error_message'])
      else
        raise Exception.new(body['data']['error_message'])
      end
    rescue
      raise Exception.new('Unknown error occurred. Please report this.')
    end
    body
  end

  private

  def self.get_params(args = {})
    # construct the parameter string
    params = ""
    args = {} if args.nil?

    args.each do |k,v|
      params += '&' if params.length > 0
      params += "#{k.to_s}=#{v.to_s}"
    end

    return params
  end

  public

  class Key

    def initialize(privkey = nil, compressed = true)
      # the privkey must be in hex if at all provided

      @group = ECDSA::Group::Secp256k1
      @private_key = privkey.to_i(16) || 1 + SecureRandom.random_number(group.order - 1)
      @public_key = @group.generator.multiply_by_scalar(@private_key)
      @compressed = compressed

    end 

    def private_key
      # returns private key in hex form
      return @private_key.to_s(16)
    end

    def public_key
      # returns the compressed form of the public key to save network fees (shorter scripts)

      return ECDSA::Format::PointOctetString.encode(@public_key, compression: @compressed).unpack("H*")[0]
    end

    def sign(data)
      # signed the given hexadecimal string

      nonce = deterministicGenerateK([data].pack("H*"), @private_key) # RFC6979

      signature = ECDSA.sign(@group, @private_key, data.to_i(16), nonce)

      # BIP0062 -- use lower S values only
      r, s = signature.components

      over_two = @group.order >> 1 # half of what it was                     
      s = @group.order - s if (s > over_two)

      signature = ECDSA::Signature.new(r, s)

      # DER encode this, and return it in hex form
      return ECDSA::Format::SignatureDerString.encode(signature).unpack("H*")[0]
    end

    def self.from_passphrase(passphrase)
      # create a private+public key pair from a given passphrase
      # think of this as your brain wallet. be very sure to use a sufficiently long passphrase
      # if you don't want a passphrase, just use Key.new and it will generate a random key for you

      raise Exception.new('Must provide passphrase at least 8 characters long.') if passphrase.nil? or passphrase.length < 8

      hashed_key = Helper.sha256([passphrase].pack("H*")) # must pass bytes to sha256

      return Key.new(hashed_key)
    end

    def self.from_wif(wif)
      # returns a new key extracted from the Wallet Import Format provided
      # TODO check against checksum

      hexkey = Helper.decode_base58(wif)
      actual_key = hexkey[2...66]

      compressed = hexkey[2..hexkey.length].length-8 > 64 and hexkey[2..hexkey.length][64...66] == '01'

      return Key.new(actual_key, compressed)

    end

    def isPositive(i)
      sig = "!+-"[i <=> 0]

      return sig.eql?("+")
    end

    def deterministicGenerateK(data, privkey, group = ECDSA::Group::Secp256k1)
      # returns a deterministic K  -- RFC6979

      hash = data.bytes.to_a

      x = [privkey.to_s(16)].pack("H*").bytes.to_a

      k = []
      32.times { k.insert(0, 0) }

      v = []
      32.times { v.insert(0, 1) }

      # step D
      k = OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), k.pack("C*"), [].concat(v).concat([0]).concat(x).concat(hash).pack("C*")).bytes.to_a

      # step E
      v = OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), k.pack("C*"), v.pack("C*")).bytes.to_a

      #  puts "E: " + v.pack("C*").unpack("H*")[0]

      # step F
      k = OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), k.pack("C*"), [].concat(v).concat([1]).concat(x).concat(hash).pack("C*")).bytes.to_a

      # step G
      v = OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), k.pack("C*"), v.pack("C*")).bytes.to_a

      # step H2b (Step H1/H2a ignored)
      v = OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), k.pack("C*"), v.pack("C*")).bytes.to_a

      h2b = v.pack("C*").unpack("H*")[0]
      tNum = h2b.to_i(16)

      # step H3
      while (!isPositive(tNum) or tNum >= group.order) do
        # k = crypto.HmacSHA256(Buffer.concat([v, new Buffer([0])]), k)
        k = OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), k.pack("C*"), [].concat(v).concat([0]).pack("C*")).bytes.to_a

        # v = crypto.HmacSHA256(v, k)
        v = OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), k.pack("C*"), v.pack("C*")).bytes.to_a

        # T = BigInteger.fromBuffer(v)
        tNum = v.pack("C*").unpack("H*")[0].to_i(16)
      end

      return tNum
    end

  end

  module Helper

    def self.signData(inputs, keys)
      # sign the given data with the given keys
      # TODO loop is O(n^3), make it better

      raise Exception.new('Keys object must be an array of keys, without at least one key inside it.') unless keys.is_a?(Array) and keys.size >= 1

      i = 0
      while i < inputs.size do
        # iterate over all signers
        input = inputs[i]

        j = 0
        while j < input['signers'].size do
          # if our public key matches this signer's public key, sign the data
          signer = inputs[i]['signers'][j]

          k = 0
          while k < keys.size do
            # sign for each key provided, if we can
            key = keys[k]
            signer['signed_data'] = key.sign(input['data_to_sign']) if signer['signer_public_key'] == key.public_key
            k = k + 1
          end

          j = j + 1
        end

        i = i + 1
      end

      inputs
    end

    def self.extractKey(encrypted_data, b64_enc_key)
      # passphrase is in plain text
      # encrypted_data is in base64, as it was stored on Block.io
      # returns the private key extracted from the given encrypted data

      decrypted = self.decrypt(encrypted_data, b64_enc_key)

      return Key.from_passphrase(decrypted)
    end

    def self.sha256(value)
      # returns the hex of the hash of the given value
      hash = Digest::SHA2.new(256)
      hash << value
      hash.hexdigest # return hex
    end

    def self.pinToAesKey(secret_pin, iterations = 2048)
      # converts the pincode string to PBKDF2
      # returns a base64 version of PBKDF2 pincode
      salt = ""

      # pbkdf2-ruby gem uses SHA256 as the default hash function
      aes_key_bin = PBKDF2.new(:password => secret_pin, :salt => salt, :iterations => iterations/2, :key_length => 128/8).value
      aes_key_bin = PBKDF2.new(:password => aes_key_bin.unpack("H*")[0], :salt => salt, :iterations => iterations/2, :key_length => 256/8).value

      return Base64.strict_encode64(aes_key_bin) # the base64 encryption key
    end

    # Decrypts a block of data (encrypted_data) given an encryption key
    def self.decrypt(encrypted_data, b64_enc_key, iv = nil, cipher_type = 'AES-256-ECB')

      response = nil

      begin
        aes = OpenSSL::Cipher.new(cipher_type)
        aes.decrypt
        aes.key = Base64.strict_decode64(b64_enc_key)
        aes.iv = iv if iv != nil
        response = aes.update(Base64.strict_decode64(encrypted_data)) + aes.final
      rescue Exception => e
        # decryption failed, must be an invalid Secret PIN
        raise Exception.new('Invalid Secret PIN provided.')
      end

      return response
    end

    # Encrypts a block of data given an encryption key
    def self.encrypt(data, b64_enc_key, iv = nil, cipher_type = 'AES-256-ECB')
      aes = OpenSSL::Cipher.new(cipher_type)
      aes.encrypt
      aes.key = Base64.strict_decode64(b64_enc_key)
      aes.iv = iv if iv != nil
      Base64.strict_encode64(aes.update(data) + aes.final)
    end

    # courtesy bitcoin-ruby

    def self.int_to_base58(int_val, leading_zero_bytes=0)
      alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
      base58_val, base = '', alpha.size
      while int_val > 0
        int_val, remainder = int_val.divmod(base)
        base58_val = alpha[remainder] + base58_val
      end
      base58_val
    end

    def self.base58_to_int(base58_val)
      alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
      int_val, base = 0, alpha.size
      base58_val.reverse.each_char.with_index do |char,index|
        raise ArgumentError, 'Value not a valid Base58 String.' unless char_index = alpha.index(char)
        int_val += char_index*(base**index)
      end
      int_val
    end

    def self.encode_base58(hex)
      leading_zero_bytes  = (hex.match(/^([0]+)/) ? $1 : '').size / 2
      ("1"*leading_zero_bytes) + Helper.int_to_base58( hex.to_i(16) )
    end

    def self.decode_base58(base58_val)
      s = Helper.base58_to_int(base58_val).to_s(16); s = (s.bytesize.odd? ? '0'+s : s)
      s = '' if s == '00'
      leading_zero_bytes = (base58_val.match(/^([1]+)/) ? $1 : '').size
      s = ("00"*leading_zero_bytes) + s  if leading_zero_bytes > 0
      s
    end
  end
end
