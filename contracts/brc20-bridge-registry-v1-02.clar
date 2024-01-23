(use-trait sip010-trait .trait-sip-010.sip-010-trait)

(define-constant err-unauthorised (err u1000))
(define-constant err-token-not-found (err u1001))
(define-constant err-request-not-found (err u1002))

(define-data-var contract-owner principal tx-sender)

(define-map peg-in-sent { tx: (buff 8192), output: uint, offset: uint } bool)

;; governance functions

(define-public (set-contract-owner-legacy (new-owner principal))
	(begin 
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 set-contract-owner new-owner))))

(define-public (approve-operator (operator principal) (approved bool))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 approve-operator operator approved))))

(define-public (set-request-revoke-grace-period (grace-period uint))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 set-request-revoke-grace-period grace-period))))

(define-public (set-request-claim-grace-period (grace-period uint))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 set-request-claim-grace-period grace-period))))

(define-public (pause-peg-in (tick (string-utf8 4)) (paused bool))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 pause-peg-in tick paused))))

(define-public (pause-peg-out (tick (string-utf8 4)) (paused bool))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 pause-peg-out tick paused))))

(define-public (set-peg-in-fee (tick (string-utf8 4)) (new-peg-in-fee uint))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 set-peg-in-fee tick new-peg-in-fee))))

(define-public (set-peg-out-fee (tick (string-utf8 4)) (new-peg-out-fee uint))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 set-peg-out-fee tick new-peg-out-fee))))

(define-public (set-peg-out-gas-fee (tick (string-utf8 4)) (new-peg-out-gas-fee uint))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 set-peg-out-gas-fee tick new-peg-out-gas-fee))))

(define-public (approve-token (tick (string-utf8 4)) (token principal) (approved bool))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 approve-token tick token approved))))

(define-public (approve-peg-in-address (address (buff 128)) (approved bool))
	(begin
		(try! (is-contract-owner))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 approve-peg-in-address address approved))))

(define-public (set-contract-owner (new-contract-owner principal))
	(begin
		(try! (is-contract-owner))
		(ok (var-set contract-owner new-contract-owner))))		

;; read-only functions

(define-read-only (get-request-revoke-grace-period)
	(contract-call? .brc20-bridge-registry-v1-01 get-request-revoke-grace-period))

(define-read-only (get-request-claim-grace-period)
	(contract-call? .brc20-bridge-registry-v1-01 get-request-claim-grace-period))

(define-read-only (is-peg-in-address-approved (address (buff 128)))
	(contract-call? .brc20-bridge-registry-v1-01 is-peg-in-address-approved address))

(define-read-only (get-token-to-tick-or-fail (token principal))
	(contract-call? .brc20-bridge-registry-v1-01 get-token-to-tick-or-fail token))

(define-read-only (get-token-details-or-fail (tick (string-utf8 4)))
	(contract-call? .brc20-bridge-registry-v1-01 get-token-details-or-fail tick))

(define-read-only (get-token-details-or-fail-by-address (token principal))
	(contract-call? .brc20-bridge-registry-v1-01 get-token-details-or-fail-by-address token))

(define-read-only (is-approved-token (tick (string-utf8 4)))
	(contract-call? .brc20-bridge-registry-v1-01 is-approved-token tick))

(define-read-only (get-request-or-fail (request-id uint))
	(contract-call? .brc20-bridge-registry-v1-01 get-request-or-fail request-id))

(define-read-only (get-approved-operator-or-default (operator principal))
	(contract-call? .brc20-bridge-registry-v1-01 get-approved-operator-or-default operator))

(define-read-only (get-peg-in-sent-or-default (bitcoin-tx (buff 8192)) (output uint) (offset uint))
	(match (as-max-len? bitcoin-tx u4096)
		some-value
		(or 
			(contract-call? .brc20-bridge-registry-v1-01 get-peg-in-sent-or-default some-value output offset)
			(default-to false (map-get? peg-in-sent { tx: bitcoin-tx, output: output, offset: offset })))
		(default-to false (map-get? peg-in-sent { tx: bitcoin-tx, output: output, offset: offset }))))

(define-read-only (is-approved-operator)
	(contract-call? .brc20-bridge-registry-v1-01 is-approved-operator))

;; priviledged functions

(define-public (set-peg-in-sent (peg-in-tx { tx: (buff 8192), output: uint, offset: uint }) (sent bool))
	(begin
		(try! (is-approved-operator))
		(ok (map-set peg-in-sent peg-in-tx sent))))

(define-public (set-request (request-id uint) (details { requested-by: principal, peg-out-address: (buff 128), tick: (string-utf8 4), amount-net: uint, fee: uint, gas-fee: uint, claimed: uint, claimed-by: principal, fulfilled-by: (buff 128), revoked: bool, finalized: bool, requested-at: uint, requested-at-burn-height: uint}))
	(begin
		(try! (is-approved-operator))
		(as-contract (contract-call? .brc20-bridge-registry-v1-01 set-request request-id details))))

;; internal functions

(define-private (is-contract-owner)
	(ok (asserts! (is-eq (var-get contract-owner) tx-sender) err-unauthorised)))

