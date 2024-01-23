(use-trait sip010-trait .trait-sip-010.sip-010-trait)

(define-constant err-unauthorised (err u1000))
(define-constant err-request-not-found (err u1002))
(define-constant err-invalid-input (err u1003))

(define-data-var contract-owner principal tx-sender)

(define-map peg-in-sent { tx: (buff 16384), output: uint } bool)

;; governance functions

(define-public (set-contract-owner (new-contract-owner principal))
	(begin
		(try! (is-contract-owner))
		(ok (var-set contract-owner new-contract-owner))))

(define-public (set-contract-owner-legacy (new-owner principal))
	(begin 
		(try! (is-contract-owner))
		(as-contract (contract-call? .btc-bridge-registry-v1-02 set-contract-owner new-owner))))

(define-public (approve-operator (operator principal) (approved bool))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .btc-bridge-registry-v1-02 approve-operator operator approved))))

(define-public (set-request-revoke-grace-period (grace-period uint))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .btc-bridge-registry-v1-02 set-request-revoke-grace-period grace-period))))

(define-public (set-request-claim-grace-period (grace-period uint))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .btc-bridge-registry-v1-02 set-request-claim-grace-period grace-period))))

(define-public (approve-peg-in-address (address (buff 128)) (approved bool))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .btc-bridge-registry-v1-02 approve-peg-in-address address approved))))

;; read-only functions

(define-read-only (get-request-revoke-grace-period)
	(contract-call? .btc-bridge-registry-v1-02 get-request-revoke-grace-period))

(define-read-only (get-request-claim-grace-period)
	(contract-call? .btc-bridge-registry-v1-02 get-request-claim-grace-period))

(define-read-only (is-peg-in-address-approved (address (buff 128)))
	(contract-call? .btc-bridge-registry-v1-02 is-peg-in-address-approved address))

(define-read-only (get-request-or-fail (request-id uint))
	(contract-call? .btc-bridge-registry-v1-02 get-request-or-fail request-id))

(define-read-only (get-approved-operator-or-default (operator principal))
	(contract-call? .btc-bridge-registry-v1-02 get-approved-operator-or-default operator))

(define-read-only (is-approved-operator)
	(contract-call? .btc-bridge-registry-v1-02 is-approved-operator))

(define-read-only (get-peg-in-sent-or-default (tx (buff 16384)) (output uint))
	(match (as-max-len? tx u4096)
		some-value
		(or 
			(contract-call? .btc-bridge-registry-v1-02 get-peg-in-sent-or-default some-value output)
			(default-to false (map-get? peg-in-sent { tx: tx, output: output })))
		(default-to false (map-get? peg-in-sent { tx: tx, output: output }))))

;; priviledged functions

(define-public (set-peg-in-sent (tx (buff 16384)) (output uint) (sent bool))
	(begin
		(try! (is-approved-operator))
		(ok (map-set peg-in-sent { tx: tx, output: output } sent))))

(define-public (set-request (request-id uint) (details { requested-by: principal, peg-out-address: (buff 128), amount-net: uint, fee: uint, gas-fee: uint, claimed: uint, claimed-by: principal, fulfilled-by: (buff 128), revoked: bool, finalized: bool, requested-at: uint, requested-at-burn-height: uint}))
	(begin
		(try! (is-approved-operator))
		(contract-call? .btc-bridge-registry-v1-02 set-request request-id details)))

;; internal functions

(define-private (is-contract-owner)
	(ok (asserts! (is-eq (var-get contract-owner) tx-sender) err-unauthorised)))

