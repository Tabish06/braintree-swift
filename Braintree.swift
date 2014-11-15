import Foundation

/// Braintree v.zero for iOS and OS X
public struct Braintree {
    /// The current version of the library
    public static let Version = "0.0.1"

    public static let ErrorDomain = "BraintreeSwiftErrorDomain"

    public enum ErrorCode : Int {
        case APIError = 1
        case InternalError = 2
    }

    /// The customer's raw payment method details for uploading to Braintree
    ///
    ///  - Card: Payment details for a credit or debit card
    public enum TokenizationRequest {
        /// A payment method's expiration date
        public struct Expiration {
            public let expirationDate : String

            /// Initialize a TokenizationRequest based on an expiration date string
            ///
            ///
            ///  :param: expirationDate the human-friendly expiration date, formatted "MM/YY", "MM/YYYY" or YYYY-MM
            ///
            ///  :returns: An expiration
            public init(expirationDate : String) {
                self.expirationDate = expirationDate
            }

            /// Initialize a TokenizationRequest based on an expiration month and year
            ///
            ///  :param: expirationMonth expiration month 1-12
            ///  :param: expirationYear  expiration year, such as 2014
            ///
            ///  :returns: An expiration
            public init(expirationMonth : Int, expirationYear : Int) {
                expirationDate = "\(expirationMonth)/\(expirationYear)"
            }
        }

        ///  A credit card tokenization request for credit cards, debit cards, etc.
        ///
        ///  :param: number     A Luhn-10 valid card number
        ///  :param: expiration The card's expiration date
        ///
        ///  :returns: An object that can be tokenized with Braintree in exchange for a payment method nonce
        case Card(number : String, expiration : Expiration)

        internal func rawParameters() -> Dictionary<String, AnyObject> {
            switch self {
            case let .Card(number, expiration):
                return ["credit_card": [
                    "number": number,
                    "expirationDate": expiration.expirationDate
                ]]
            }
        }
    }

    /// A response from Braintree's API
    ///
    ///  - PaymentMethodNonce: A payment method nonce has successfully created for the given payment method details
    ///  - RequestError:       A payment method nonce could not be created because of the request
    ///  - BraintreeError:     A payment method nonce could not be created because of Braintree
    public enum TokenizationResponse {
        case PaymentMethodNonce(nonce : String)
        case RequestError(message : String)
        case BraintreeError(message : String)
    }

    // MARK: - Client

    /// A client for interacting with Braintree's servers directly from your app
    public class Client {
        /// A function that obtains a Client Token from your server whenever this library asks for one
        ///
        /// :note: A fresh client token should be generated and fetched each time this function is called.
        public typealias ClientTokenProvider = ((String?) -> (Void)) -> Void

        // MARK: - Public Interface

        /// Initializes the Braintree Client
        ///
        /// :param: clientTokenProvider A function that can provide a fresh Client Token on demand
        ///
        /// :returns: A client that is ready to tokenize payment methods
        public required init(clientTokenProvider : ClientTokenProvider) {
            self.clientTokenProvider = clientTokenProvider
            refreshConfiguration()
        }

        /// Tokenize a customer's raw payment details, generating a payment method nonce that
        /// can safely be transmitted to your servers.
        ///
        /// :param: details    A tokenization request containing the raw payment details
        /// :param: completion A closure that is called upon completion
        public func tokenize(details : TokenizationRequest, completion : (TokenizationResponse) -> (Void)) {
            withConfiguration() {
                self.api.post("v1/payment_methods/credit_cards", parameters: details.rawParameters(), completion: { (responseObject, error) -> (Void) in
                    if let error : NSError = error {
                        return completion(.RequestError(message: error.localizedDescription))
                    }

                    if let responseObject = responseObject as? [String : AnyObject] {
                        if let creditCardsArray = responseObject["creditCards"] as? [AnyObject] {
                            if let creditCardObject = creditCardsArray[0] as? [String : AnyObject] {
                                if let nonce = creditCardObject["nonce"] as? String {
                                    return completion(.PaymentMethodNonce(nonce: nonce))
                                }
                            }
                        }
                    }

                    return completion(.BraintreeError(message: "Invalid Response Format"))
                })
            }
        }

        // MARK: Internal State

        private let clientTokenProvider : ClientTokenProvider

        private var configuration : Configuration? {
            didSet {
                if let configuration = configuration {
                    self.api.baseURL = configuration.clientApiBaseURL
                    self.api.authorizationFingerprint = configuration.authorizationFingerprint
                    for configurationHandler in withConfigurationQueue {
                        configurationHandler()
                    }
                    withConfigurationQueue.removeAll(keepCapacity: false)
                }
            }
        }

        private var withConfigurationQueue : [(Void) -> (Void)] = []

        private let api : API = API()

        // MARK: Internal Helpers

        private func refreshConfiguration() {
            self.clientTokenProvider() { [weak self] clientToken in
                if let clientToken = clientToken {
                    if let decodedClientTokenData = NSData(base64EncodedString: clientToken, options : nil) {
                        if let clientTokenObject = NSJSONSerialization.JSONObjectWithData(decodedClientTokenData, options: nil, error: nil) as? Dictionary<String, AnyObject> {
                            if let version = clientTokenObject["version"] as? Int {
                                if let baseURLString = clientTokenObject["clientApiUrl"] as? String {
                                    if let baseURL = NSURL(string: baseURLString) {
                                        if let authorizationFingerprint = clientTokenObject["authorizationFingerprint"] as? String {
                                            self?.configuration = Configuration(clientApiBaseURL: baseURL, authorizationFingerprint: authorizationFingerprint)
                                        }  else {
                                            return println("Braintree: Invalid client token (missing authorization fingerprint)")
                                        }
                                    } else {
                                        return println("Braintree: Invalid client token (invalid clientApiUrl)")
                                    }
                                } else {
                                    return println("Braintree: Invalid client token (missing clientApiUrl)")
                                }
                            } else {
                                return println("Braintree: Invalid client token (unsupported version)")
                            }
                        } else {
                            return println("Braintree: Invalid client token (unsupported format)")
                        }
                    } else {
                        return println("Braintree: Invalid client token (unsupported format)")
                    }
                } else {
                    return println("Braintree: Client token was not returned when requested by client token provider")
                }
            }
        }

        private func withConfiguration(completion : (Void) -> (Void)) {
            if configuration != nil {
                completion()
            } else {
                withConfigurationQueue.append(completion)
            }
        }

        // MARK: - Payment Method Tokenization
    }

    // MARK: - Types

    internal struct Configuration {
        let clientApiBaseURL : NSURL
        let authorizationFingerprint : String
    }

    // MARK: - API Client

    internal class API {
        typealias CompletionHandler = ((_ : AnyObject!, _ : NSError!) -> (Void))?

        private var baseURLComponents : NSURLComponents?
        private var authorizationFingerprint : String?

        private var session : NSURLSession {
            let configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration()
            configuration.HTTPAdditionalHeaders = [
                "User-Agent": "Braintree/Swift/\(Braintree.Version)",
                "Accept": "application/json",
                "Accept-Language": "en_US"
            ]

            return NSURLSession(configuration: configuration, delegate: nil, delegateQueue: NSOperationQueue.mainQueue())
        }

        var baseURL : NSURL?

        required init() {
        }

        func post(path : String, parameters : Dictionary<String, AnyObject>?, completion : CompletionHandler) {
            request("post", path: path, parameters: parameters, completion: completion)
        }

        internal func request(method: String, path: String, parameters: Dictionary<String, AnyObject>?, completion: CompletionHandler) {
            if let baseURL = baseURL {
                if let pathComponents = NSURLComponents(URL: baseURL.URLByAppendingPathComponent(path), resolvingAgainstBaseURL: false) {
                    let legalURLCharactersToBeEscaped: CFStringRef = ":/?&=;+!@#$()',*"
                    let authorizationFingerprint = CFURLCreateStringByAddingPercentEscapes(
                        nil,
                        self.authorizationFingerprint,
                        nil,
                        legalURLCharactersToBeEscaped,
                        CFStringBuiltInEncodings.UTF8.rawValue
                    )

                    pathComponents.percentEncodedQuery = "authorizationFingerprint=\(authorizationFingerprint)"

                    if let URL = pathComponents.URL {
                        let request = NSMutableURLRequest(URL: URL)
                        request.HTTPMethod = method

                        if let parameters = parameters {
                            var JSONSerializationError : NSError?
                            request.HTTPBody = NSJSONSerialization.dataWithJSONObject(parameters, options: nil, error: &JSONSerializationError)
                            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

                            if let error = JSONSerializationError {
                                if let completion = completion {
                                    completion(nil, error)
                                    return
                                }
                            }
                        }

                        print("[Braintree] API Request: ")
                        debugPrintln(request)
                        session.dataTaskWithRequest(request, completionHandler: { (data, response, error) -> Void in
                            if let response : NSHTTPURLResponse = response as? NSHTTPURLResponse {
                                let broxyId = response.allHeaderFields["X-BroxyId"] as String? ?? ""
                                println("[Braintree] API Response [\(broxyId)]: ")
                                debugPrintln(response)
                                if let completion = completion {
                                    if error != nil {
                                        completion(nil, error)
                                    } else if response.statusCode >= 300 {
                                        var responseObject : Dictionary<String, AnyObject>?

                                        if data.length > 0 && startsWith(response.allHeaderFields["Content-Type"] as String, "application/json") {
                                            var jsonError : NSError?
                                            responseObject = NSJSONSerialization.JSONObjectWithData(data, options: nil, error: &jsonError) as Dictionary<String, AnyObject>!
                                            if let error = jsonError {
                                                completion(nil, error)
                                            }
                                        }

                                        let error = Braintree.error(Braintree.ErrorCode.APIError, message: "Failed to save credit card")
                                        completion(responseObject, error)
                                    } else {
                                        let responseObject : Dictionary<String, AnyObject>! = NSJSONSerialization.JSONObjectWithData(data, options: nil, error: nil) as Dictionary<String, AnyObject>!
                                        completion(responseObject, nil)
                                    }
                                }
                            }
                        }).resume()
                    } else {
                        let error = Braintree.error(.InternalError, message: "Invalid URL")
                        if let completion = completion {
                            completion(nil, error)
                        }
                        return
                    }
                }
            }
        }
    }
    
    internal static func error(code: Braintree.ErrorCode, message : String) -> NSError {
        return NSError(domain: Braintree.ErrorDomain,
            code: Braintree.ErrorCode.InternalError.rawValue,
            userInfo: [ NSLocalizedDescriptionKey: "Invalid URL" ])
    }
}