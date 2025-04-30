;; Gratitude Journal
;; A smart contract for recording and managing personal gratitude entries
;; with mood tracking, privacy controls, and achievement systems.

;; =========================================
;; Constants & Error Codes
;; =========================================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ENTRY-NOT-FOUND (err u101))
(define-constant ERR-INVALID-MOOD (err u102))
(define-constant ERR-ENTRY-TOO-LONG (err u103))
(define-constant ERR-INVALID-PRIVACY (err u104))
(define-constant ERR-STREAK-ALREADY-CLAIMED (err u105))

;; Other constants
(define-constant MAX-ENTRY-LENGTH u500)
(define-constant MAX-MOOD-VALUE u10)
(define-constant PRIVATE-ENTRY u0)
(define-constant PUBLIC-ENTRY u1)
(define-constant WEEKLY-ACHIEVEMENT-THRESHOLD u7)
(define-constant MONTHLY-ACHIEVEMENT-THRESHOLD u30)

;; =========================================
;; Data Maps & Variables
;; =========================================

;; Main storage for gratitude entries
(define-map gratitude-entries 
  { owner: principal, entry-id: uint }
  {
    text: (string-utf8 MAX-ENTRY-LENGTH),
    mood: uint,
    timestamp: uint,
    is-public: bool
  }
)

;; Index to track all entry IDs per user
(define-map user-entries 
  { owner: principal }
  { entry-ids: (list 100 uint) }
)

;; Counter for each user's entries
(define-map entry-count 
  { owner: principal }
  { count: uint }
)

;; Track user achievements
(define-map user-achievements
  { owner: principal }
  {
    weekly-streaks: uint,
    monthly-streaks: uint,
    last-streak-claimed: uint
  }
)

;; Track user's last entry timestamp for streak calculation
(define-map user-last-entry
  { owner: principal }
  { timestamp: uint }
)

;; =========================================
;; Private Functions
;; =========================================

;; Initialize user-entries if they don't exist yet
(define-private (initialize-user-entries (user principal))
  (match (map-get? user-entries { owner: user })
    entry-map entry-map
    (map-set user-entries { owner: user } { entry-ids: (list) })
  )
)

;; Initialize entry counter if it doesn't exist
(define-private (initialize-entry-count (user principal))
  (match (map-get? entry-count { owner: user })
    count-map count-map
    (map-set entry-count { owner: user } { count: u0 })
  )
)

;; Initialize user achievements if they don't exist
(define-private (initialize-achievements (user principal))
  (match (map-get? user-achievements { owner: user })
    achievements achievements
    (map-set user-achievements 
      { owner: user } 
      { 
        weekly-streaks: u0, 
        monthly-streaks: u0,
        last-streak-claimed: u0
      }
    )
  )
)

;; Get the current user entry count
(define-private (get-user-entry-count (user principal))
  (default-to 
    { count: u0 }
    (map-get? entry-count { owner: user })
  )
)

;; Get the next entry ID for a user
(define-private (get-next-entry-id (user principal))
  (let ((current-count (get user-entry-count (get-user-entry-count user))))
    current-count
  )
)

;; Add an entry ID to user's list of entries
(define-private (add-entry-to-user-list (user principal) (entry-id uint))
  (let (
    (current-entries (default-to { entry-ids: (list) } (map-get? user-entries { owner: user })))
    (updated-entries (unwrap-panic (as-max-len? (append (get entry-ids current-entries) entry-id) u100)))
  )
    (map-set user-entries { owner: user } { entry-ids: updated-entries })
  )
)

;; Increment user's entry count
(define-private (increment-entry-count (user principal))
  (let (
    (current-count (get-user-entry-count user))
  )
    (map-set entry-count 
      { owner: user } 
      { count: (+ (get count current-count) u1) }
    )
    (get count (get-user-entry-count user))
  )
)

;; Update user's last entry timestamp and check for streaks
(define-private (update-last-entry (user principal))
  (let (
    (current-time (unwrap-panic (get-block-info? time u0)))
    (previous-entry (default-to { timestamp: u0 } (map-get? user-last-entry { owner: user })))
  )
    ;; Update the last entry timestamp
    (map-set user-last-entry { owner: user } { timestamp: current-time })
    
    ;; Check if this is creating a streak
    (if (is-consecutive-day (get timestamp previous-entry) current-time)
      (check-and-update-streaks user)
      true
    )
  )
)

;; Determine if two timestamps are from consecutive days
(define-private (is-consecutive-day (previous uint) (current uint))
  (let (
    (day-seconds (* u60 u60 u24))
    (two-days-seconds (* day-seconds u2))
  )
    (and 
      ;; Previous timestamp exists (not the first entry)
      (> previous u0)
      ;; Current timestamp is within 2 days of previous
      (< (- current previous) two-days-seconds)
      ;; Current timestamp is more than 12 hours from previous
      (> (- current previous) (* u60 u60 u12))
    )
  )
)

;; Check and update achievement streaks
(define-private (check-and-update-streaks (user principal))
  (let (
    (current-time (unwrap-panic (get-block-info? time u0)))
    (achievements (default-to 
      { weekly-streaks: u0, monthly-streaks: u0, last-streak-claimed: u0 } 
      (map-get? user-achievements { owner: user })
    ))
    (last-claimed (get last-streak-claimed achievements))
    (week-seconds (* u60 u60 u24 u7))
    (month-seconds (* u60 u60 u24 u30))
  )
    ;; Check if we need to update weekly streak
    (if (and (>= (- current-time last-claimed) week-seconds)
             (>= (get weekly-streaks achievements) WEEKLY-ACHIEVEMENT-THRESHOLD))
      (map-set user-achievements 
        { owner: user } 
        {
          weekly-streaks: (+ (get weekly-streaks achievements) u1),
          monthly-streaks: (get monthly-streaks achievements),
          last-streak-claimed: current-time
        }
      )
      
      ;; Check if we need to update monthly streak
      (if (and (>= (- current-time last-claimed) month-seconds)
               (>= (get monthly-streaks achievements) MONTHLY-ACHIEVEMENT-THRESHOLD))
        (map-set user-achievements 
          { owner: user } 
          {
            weekly-streaks: (get weekly-streaks achievements),
            monthly-streaks: (+ (get monthly-streaks achievements) u1),
            last-streak-claimed: current-time
          }
        )
        true
      )
    )
  )
)

;; Validate mood value
(define-private (is-valid-mood (mood uint))
  (<= mood MAX-MOOD-VALUE)
)

;; Validate privacy setting
(define-private (is-valid-privacy (privacy uint))
  (or (is-eq privacy PRIVATE-ENTRY) (is-eq privacy PUBLIC-ENTRY))
)

;; =========================================
;; Read-Only Functions
;; =========================================

;; Get a specific entry by ID
(define-read-only (get-entry (owner principal) (entry-id uint))
  (let (
    (entry (map-get? gratitude-entries { owner: owner, entry-id: entry-id }))
  )
    (match entry
      value (ok value)
      (err ERR-ENTRY-NOT-FOUND)
    )
  )
)

;; Get all entries for a specific user
(define-read-only (get-user-entries (user principal))
  (let (
    (entries-map (default-to { entry-ids: (list) } (map-get? user-entries { owner: user })))
  )
    (ok (get entry-ids entries-map))
  )
)

;; Get user achievements
(define-read-only (get-user-achievements (user principal))
  (let (
    (achievements (default-to
      { weekly-streaks: u0, monthly-streaks: u0, last-streak-claimed: u0 }
      (map-get? user-achievements { owner: user })
    ))
  )
    (ok achievements)
  )
)

;; Get most recent public entries
(define-read-only (get-public-entries (limit uint))
  ;; Note: In a production contract, this would require off-chain indexing
  ;; since Clarity doesn't allow iterating through all entries
  ;; This is a simplified placeholder
  (ok (list))
)

;; =========================================
;; Public Functions
;; =========================================

;; Create a new gratitude entry
(define-public (create-entry (text (string-utf8 MAX-ENTRY-LENGTH)) (mood uint) (is-public bool))
  (let (
    (user tx-sender)
    (entry-id (get-next-entry-id user))
    (current-time (unwrap-panic (get-block-info? time u0)))
  )
    ;; Validate inputs
    (asserts! (is-valid-mood mood) ERR-INVALID-MOOD)
    (asserts! (<= (len text) MAX-ENTRY-LENGTH) ERR-ENTRY-TOO-LONG)
    
    ;; Initialize user data structures if needed
    (initialize-user-entries user)
    (initialize-entry-count user)
    (initialize-achievements user)
    
    ;; Create the entry
    (map-set gratitude-entries
      { owner: user, entry-id: entry-id }
      { 
        text: text,
        mood: mood,
        timestamp: current-time,
        is-public: is-public
      }
    )
    
    ;; Update user data
    (add-entry-to-user-list user entry-id)
    (increment-entry-count user)
    (update-last-entry user)
    
    (ok entry-id)
  )
)

;; Update privacy setting for an entry
(define-public (update-privacy (entry-id uint) (is-public bool))
  (let (
    (user tx-sender)
    (entry (map-get? gratitude-entries { owner: user, entry-id: entry-id }))
  )
    ;; Check if entry exists and belongs to user
    (asserts! (is-some entry) ERR-ENTRY-NOT-FOUND)
    
    ;; Update the privacy setting
    (map-set gratitude-entries
      { owner: user, entry-id: entry-id }
      (merge (unwrap-panic entry) { is-public: is-public })
    )
    
    (ok true)
  )
)

;; Update mood for an entry
(define-public (update-mood (entry-id uint) (mood uint))
  (let (
    (user tx-sender)
    (entry (map-get? gratitude-entries { owner: user, entry-id: entry-id }))
  )
    ;; Check if entry exists and belongs to user
    (asserts! (is-some entry) ERR-ENTRY-NOT-FOUND)
    (asserts! (is-valid-mood mood) ERR-INVALID-MOOD)
    
    ;; Update the mood
    (map-set gratitude-entries
      { owner: user, entry-id: entry-id }
      (merge (unwrap-panic entry) { mood: mood })
    )
    
    (ok true)
  )
)

;; Delete an entry
(define-public (delete-entry (entry-id uint))
  (let (
    (user tx-sender)
    (entry (map-get? gratitude-entries { owner: user, entry-id: entry-id }))
  )
    ;; Check if entry exists and belongs to user
    (asserts! (is-some entry) ERR-ENTRY-NOT-FOUND)
    
    ;; Delete the entry
    (map-delete gratitude-entries { owner: user, entry-id: entry-id })
    
    ;; Note: We don't remove from the entry-ids list since that would require rebuilding the list
    ;; In a production system, we might want a more sophisticated approach
    
    (ok true)
  )
)

;; Claim streak achievement 
;; This would typically interact with a separate token contract in production
(define-public (claim-streak-achievement)
  (let (
    (user tx-sender)
    (current-time (unwrap-panic (get-block-info? time u0)))
    (achievements (default-to 
      { weekly-streaks: u0, monthly-streaks: u0, last-streak-claimed: u0 } 
      (map-get? user-achievements { owner: user })
    ))
  )
    ;; Check if user has any unclaimed achievements
    (asserts! (or (> (get weekly-streaks achievements) u0)
                  (> (get monthly-streaks achievements) u0))
              ERR-STREAK-ALREADY-CLAIMED)
    
    ;; In a production contract, this would mint achievement tokens
    ;; For this implementation, we simply reset the counters
    
    (map-set user-achievements
      { owner: user }
      {
        weekly-streaks: u0,
        monthly-streaks: u0,
        last-streak-claimed: current-time
      }
    )
    
    (ok true)
  )
)