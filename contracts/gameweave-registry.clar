;; gameweave-registry
;; 
;; This contract serves as the central registry for the GameWeave ecosystem, maintaining
;; a database of registered games and their NFT compatibility specifications. It enables
;; cross-game NFT interoperability by allowing game developers to register their games
;; and define how their assets translate across different gaming environments within the network.

;; ========================================
;; Constants
;; ========================================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-GAME-EXISTS (err u101))
(define-constant ERR-GAME-NOT-FOUND (err u102))
(define-constant ERR-INVALID-PARAMS (err u103))
(define-constant ERR-MAPPING-EXISTS (err u104))
(define-constant ERR-MAPPING-NOT-FOUND (err u105))
(define-constant ERR-INVALID-METADATA (err u106))

;; ========================================
;; Data Maps & Variables
;; ========================================

;; Game data structure
;; Stores basic information about each registered game
(define-map games
  { game-id: (string-ascii 64) }
  {
    name: (string-ascii 128),
    developer: principal,
    website: (string-utf8 256),
    description: (string-utf8 1024),
    asset-contract: principal,
    created-at: uint,
    active: bool
  }
)

;; Game administrators map
;; Allows games to have multiple admin addresses that can update settings
(define-map game-admins
  { game-id: (string-ascii 64), admin: principal }
  { allowed: bool }
)

;; NFT attribute schema
;; Defines the attributes structure for a game's NFTs
(define-map nft-schemas
  { game-id: (string-ascii 64) }
  { 
    attributes: (list 20 (string-ascii 64)),  ;; List of attribute names
    schema-version: uint
  }
)

;; Cross-game asset mappings
;; Defines how NFT attributes from source game map to target game
(define-map asset-mappings
  { source-game: (string-ascii 64), target-game: (string-ascii 64) }
  {
    attribute-map: (list 20 { 
      source-attr: (string-ascii 64), 
      target-attr: (string-ascii 64),
      transform-function: (optional (string-ascii 64))
    }),
    conversion-rules: (string-utf8 1024),  ;; JSON string of additional rules
    approved-by-source: bool,
    approved-by-target: bool,
    active: bool
  }
)

;; Registry admin
(define-data-var registry-admin principal tx-sender)

;; ========================================
;; Private Functions
;; ========================================

;; Check if caller is registry admin
(define-private (is-registry-admin)
  (is-eq tx-sender (var-get registry-admin))
)

;; Check if caller is authorized for a game
(define-private (is-game-admin (game-id (string-ascii 64)))
  (or
    (is-registry-admin)
    (default-to false (get allowed (map-get? game-admins { game-id: game-id, admin: tx-sender })))
    (is-eq tx-sender (get developer (default-to { developer: tx-sender } (map-get? games { game-id: game-id }))))
  )
)

;; Check if game exists
(define-private (game-exists (game-id (string-ascii 64)))
  (is-some (map-get? games { game-id: game-id }))
)

;; ========================================
;; Read-Only Functions
;; ========================================

;; Get game information
(define-read-only (get-game (game-id (string-ascii 64)))
  (map-get? games { game-id: game-id })
)

;; Get game schema
(define-read-only (get-game-schema (game-id (string-ascii 64)))
  (map-get? nft-schemas { game-id: game-id })
)

;; Check if principal is admin for a game
(define-read-only (is-admin-for-game (game-id (string-ascii 64)) (admin principal))
  (or
    (is-eq admin (var-get registry-admin))
    (default-to false (get allowed (map-get? game-admins { game-id: game-id, admin: admin })))
    (is-eq admin (get developer (default-to { developer: principal-zero } (map-get? games { game-id: game-id }))))
  )
)

;; Get mapping between two games
(define-read-only (get-asset-mapping (source-game (string-ascii 64)) (target-game (string-ascii 64)))
  (map-get? asset-mappings { source-game: source-game, target-game: target-game })
)

;; Check if two games have an active mapping
(define-read-only (has-active-mapping (source-game (string-ascii 64)) (target-game (string-ascii 64)))
  (match (map-get? asset-mappings { source-game: source-game, target-game: target-game })
    mapping (and
              (get approved-by-source mapping)
              (get approved-by-target mapping)
              (get active mapping))
    false
  )
)

;; ========================================
;; Public Functions
;; ========================================

;; Register a new game in the GameWeave ecosystem
(define-public (register-game
  (game-id (string-ascii 64))
  (name (string-ascii 128))
  (website (string-utf8 256))
  (description (string-utf8 1024))
  (asset-contract principal))
  
  (let
    ((current-time (unwrap-panic (get-block-info? time u0))))
    
    ;; Check if game ID already exists
    (asserts! (not (game-exists game-id)) ERR-GAME-EXISTS)
    
    ;; Validate inputs
    (asserts! (> (len game-id) u0) ERR-INVALID-PARAMS)
    (asserts! (> (len name) u0) ERR-INVALID-PARAMS)
    
    ;; Add game to registry
    (map-set games
      { game-id: game-id }
      {
        name: name,
        developer: tx-sender,
        website: website,
        description: description,
        asset-contract: asset-contract,
        created-at: current-time,
        active: true
      })
    
    ;; Return success with game ID
    (ok game-id))
)

;; Update game information
(define-public (update-game-info
  (game-id (string-ascii 64))
  (name (string-ascii 128))
  (website (string-utf8 256))
  (description (string-utf8 1024))
  (asset-contract principal)
  (active bool))
  
  (begin
    ;; Check game exists
    (asserts! (game-exists game-id) ERR-GAME-NOT-FOUND)
    
    ;; Check authorization
    (asserts! (is-game-admin game-id) ERR-NOT-AUTHORIZED)
    
    ;; Get existing game data
    (let ((game-data (unwrap! (map-get? games { game-id: game-id }) ERR-GAME-NOT-FOUND)))
      
      ;; Update game information
      (map-set games
        { game-id: game-id }
        {
          name: name,
          developer: (get developer game-data),
          website: website,
          description: description,
          asset-contract: asset-contract,
          created-at: (get created-at game-data),
          active: active
        })
      
      ;; Return success
      (ok true))
  )
)

;; Add admin for a game
(define-public (add-game-admin (game-id (string-ascii 64)) (admin principal))
  (begin
    ;; Check game exists
    (asserts! (game-exists game-id) ERR-GAME-NOT-FOUND)
    
    ;; Check authorization
    (asserts! (is-game-admin game-id) ERR-NOT-AUTHORIZED)
    
    ;; Add admin
    (map-set game-admins
      { game-id: game-id, admin: admin }
      { allowed: true })
    
    ;; Return success
    (ok true))
)

;; Remove admin for a game
(define-public (remove-game-admin (game-id (string-ascii 64)) (admin principal))
  (begin
    ;; Check game exists
    (asserts! (game-exists game-id) ERR-GAME-NOT-FOUND)
    
    ;; Check authorization
    (asserts! (is-game-admin game-id) ERR-NOT-AUTHORIZED)
    
    ;; Remove admin
    (map-set game-admins
      { game-id: game-id, admin: admin }
      { allowed: false })
    
    ;; Return success
    (ok true))
)

;; Set NFT attribute schema for a game
(define-public (set-nft-schema
  (game-id (string-ascii 64))
  (attributes (list 20 (string-ascii 64)))
  (schema-version uint))
  
  (begin
    ;; Check game exists
    (asserts! (game-exists game-id) ERR-GAME-NOT-FOUND)
    
    ;; Check authorization
    (asserts! (is-game-admin game-id) ERR-NOT-AUTHORIZED)
    
    ;; Validate inputs
    (asserts! (> (len attributes) u0) ERR-INVALID-METADATA)
    
    ;; Set schema
    (map-set nft-schemas
      { game-id: game-id }
      {
        attributes: attributes,
        schema-version: schema-version
      })
    
    ;; Return success
    (ok true))
)

;; Create or update asset mapping between two games
(define-public (set-asset-mapping
  (source-game (string-ascii 64))
  (target-game (string-ascii 64))
  (attribute-map (list 20 { 
    source-attr: (string-ascii 64), 
    target-attr: (string-ascii 64),
    transform-function: (optional (string-ascii 64))
  }))
  (conversion-rules (string-utf8 1024)))
  
  (begin
    ;; Check both games exist
    (asserts! (game-exists source-game) ERR-GAME-NOT-FOUND)
    (asserts! (game-exists target-game) ERR-GAME-NOT-FOUND)
    
    ;; Check authorization (must be admin of source game)
    (asserts! (is-game-admin source-game) ERR-NOT-AUTHORIZED)
    
    ;; Validate input
    (asserts! (> (len attribute-map) u0) ERR-INVALID-METADATA)
    
    ;; Get existing mapping if any
    (let ((existing-mapping (map-get? asset-mappings { source-game: source-game, target-game: target-game })))
      
      ;; Determine if approved by target (keep existing approval if update)
      (let ((target-approved (match existing-mapping
                               mapping (get approved-by-target mapping)
                               false)))
        
        ;; Set mapping
        (map-set asset-mappings
          { source-game: source-game, target-game: target-game }
          {
            attribute-map: attribute-map,
            conversion-rules: conversion-rules,
            approved-by-source: true,
            approved-by-target: target-approved,
            active: (and true target-approved)
          })
        
        ;; Return success
        (ok true)))
  )
)

;; Approve asset mapping as target game
(define-public (approve-asset-mapping
  (source-game (string-ascii 64))
  (target-game (string-ascii 64))
  (approve bool))
  
  (begin
    ;; Check both games exist
    (asserts! (game-exists source-game) ERR-GAME-NOT-FOUND)
    (asserts! (game-exists target-game) ERR-GAME-NOT-FOUND)
    
    ;; Check authorization (must be admin of target game)
    (asserts! (is-game-admin target-game) ERR-NOT-AUTHORIZED)
    
    ;; Check mapping exists
    (let ((mapping (unwrap! (map-get? asset-mappings { source-game: source-game, target-game: target-game }) ERR-MAPPING-NOT-FOUND)))
      
      ;; Update mapping approval
      (map-set asset-mappings
        { source-game: source-game, target-game: target-game }
        {
          attribute-map: (get attribute-map mapping),
          conversion-rules: (get conversion-rules mapping),
          approved-by-source: (get approved-by-source mapping),
          approved-by-target: approve,
          active: (and (get approved-by-source mapping) approve)
        })
      
      ;; Return success
      (ok true))
  )
)

;; Update registry admin
(define-public (set-registry-admin (new-admin principal))
  (begin
    ;; Check authorization
    (asserts! (is-registry-admin) ERR-NOT-AUTHORIZED)
    
    ;; Set new admin
    (var-set registry-admin new-admin)
    
    ;; Return success
    (ok true))
)