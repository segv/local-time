;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; LOCAL-TIME
;;;
;;; A package for manipulating times and dates.
;;;
;;; Based on Erik Naggum's "A Long, Painful History of Time" (1999)
;;;
;;; Authored by Daniel Lowe <dlowe@sanctuary.org>
;;;
;;; Copyright (c) 2005-2006 Daniel Lowe
;;; 
;;; Permission is hereby granted, free of charge, to any person obtaining
;;; a copy of this software and associated documentation files (the
;;; "Software"), to deal in the Software without restriction, including
;;; without limitation the rights to use, copy, modify, merge, publish,
;;; distribute, sublicense, and/or sell copies of the Software, and to
;;; permit persons to whom the Software is furnished to do so, subject to
;;; the following conditions:
;;; 
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;; 
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
;;; LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
;;; OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
;;; WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defpackage :local-time
    (:use #:cl)
  (:export #:local-time
           #:make-local-time
           #:day-of
           #:sec-of
           #:usec-of
           #:timezone-of
           #:local-time<
           #:local-time<=
           #:local-time>
           #:local-time>=
           #:local-time=
           #:local-time/=
           #:local-time-adjust
           #:maximize-time-part
           #:minimize-time-part
           #:local-time-designator
           #:encode-local-time
           #:decode-local-time
           #:parse-timestring
           #:format-timestring
           #:format-rfc3339-timestring
           #:parse-rfc3339-timestring
           #:universal-time
           #:internal-time
           #:unix-time
           #:timezone
           #:local-timezone
           #:define-timezone
           #:*default-timezone*
           #:now
           #:enable-read-macros
           #:+utc-zone+
           #:+month-names+
           #:+short-month-names+
           #:+day-names+
           #:+short-day-names+
           #:astronomical-julian-date
           #:modified-julian-date
           #:astronomical-modified-julian-date))

(in-package :local-time)

;;; Month information
(defparameter +month-names+
  '("" "January" "February" "March" "April" "May" "June" "July" "August"
    "September" "October" "November" "December"))
(defparameter +short-month-names+
  '("" "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov"
    "Dec"))

(defparameter +month-days+
  (make-array 12 :initial-contents
              (loop for length across #(0 31 30 31 30 31 31 30 31 30 31 31)
                    as days = 0 then (+ days length)
                    collect days)))

;;; Day information
(defparameter +day-names+
  '("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))

(defparameter +short-day-names+
  '("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))

;; The astronomical julian date offset is the number of days between
;; the current date and -4713-01-01T00:00:00+00:00
(defparameter +astronomical-julian-date-offset+ -2451605)

;; The modified julian date is the number of days between the current
;; date and 1858-11-17T12:00:00+00:00.  For the sake of simplicity,
;; we currently just do the date arithmetic and don't adjust for the
;; time of day.
(defparameter +modified-julian-date-offset+ -51604)

(defstruct timezone
  (transitions nil)
  (subzones nil)
  (leap-seconds nil)
  (path nil)
  (loaded nil))

(defun read-binary-integer (stream byte-count &optional (signed nil))
  "Read BYTE-COUNT bytes from the binary stream STREAM, and return an integer which is its representation in network byte order (MSB).  If SIGNED is true, interprets the most significant bit as a sign indicator."
  (loop for offset from (* (1- byte-count) 8) downto 0 by 8
        with result = 0
        do (setf (ldb (byte 8 offset) result) (read-byte stream))
        finally (if (and signed (< #x80000000 result))
                    (return (- result #x100000000))
                    (return result))))

(defun string-from-unsigned-vector (vector offset)
  "Returns a string created from the vector of unsigned bytes VECTOR starting at OFFSET which is terminated by a 0."
  (let ((null-pos (or (position 0 vector :start offset) (length vector))))
    (with-output-to-string (str)
                           (loop for idx from offset upto (1- null-pos)
                                 do (princ (code-char (aref vector idx)) str)))))

(defun realize-timezone (zone &optional reload)
  "If timezone has not already been loaded or RELOAD is non-NIL, loads the timezone information from its associated unix file."
  (when (or reload (not (timezone-loaded zone)))
    (with-open-file (inf (timezone-path zone)
                         :direction :input
                         :element-type 'unsigned-byte)
      ;; read and verify magic number
      (let ((magic-buf (make-array 4 :element-type 'unsigned-byte)))
        (read-sequence magic-buf inf :start 0 :end 4)
        (when (string/= (map 'string #'code-char magic-buf) "TZif" :end1 4)
          (error "~a is not a timezone file." (timezone-path zone))))
      ;; skip 16 bytes for "future use"
      (let ((ignore-buf (make-array 16 :element-type 'unsigned-byte)))
        (read-sequence ignore-buf inf :start 0 :end 16))
      ;; read header values
      (let ((utc-indicator-count (read-binary-integer inf 4))
            (wall-indicator-count (read-binary-integer inf 4))
            (leap-count (read-binary-integer inf 4))
            (transition-count (read-binary-integer inf 4))
            (type-count (read-binary-integer inf 4))
            (abbrev-length (read-binary-integer inf 4)))
        (let ((timezone-transitions
               ;; read transition times
               (loop for idx from 1 upto transition-count
                     collect (read-binary-integer inf 4 t)))
              ;; read local time indexes
              (local-time-indexes
               (loop for idx from 1 upto transition-count
                     collect (read-binary-integer inf 1)))
              ;; read local time info
              (local-time-info
               (loop for idx from 1 upto type-count
                     collect (list (read-binary-integer inf 4 t)
                                   (/= (read-binary-integer inf 1) 0)
                                   (read-binary-integer inf 1))))
              ;; read leap second info
              (leap-second-info
               (loop for idx from 1 upto leap-count
                     collect (list (read-binary-integer inf 4)
                                   (read-binary-integer inf 4))))
              (abbreviation-buf (make-array abbrev-length :element-type 'unsigned-byte)))
          (read-sequence abbreviation-buf inf :start 0 :end abbrev-length)
          (let ((wall-indicators
                 ;; read standard/wall indicators
                 (loop for idx from 1 upto wall-indicator-count
                       collect (read-binary-integer inf 1)))
                ;; read UTC/local indicators
                (local-indicators
                 (loop for idx from 1 upto utc-indicator-count
                       collect (read-binary-integer inf 1))))
            (setf (timezone-transitions zone)
                  (nreverse
                   (mapcar
                    (lambda (info index)
                      (list info index))
                    timezone-transitions
                    local-time-indexes)))
            (setf (timezone-subzones zone)
                  (mapcar
                   (lambda (info wall utc)
                     (list (first info)
                           (second info)
                           (string-from-unsigned-vector abbreviation-buf (third info))
                           (/= wall 0)
                           (/= utc 0)))
                   local-time-info
                   wall-indicators
                   local-indicators))
            (setf (timezone-leap-seconds zone)
                  leap-second-info)))))
    (setf (timezone-loaded zone) t))
  zone)

(defmacro define-timezone (zone-name zone-file &key (load nil))
  "Define zone-name (a symbol or a string) as a new timezone, lazy-loaded from zone-file (a pathname designator relative to the zoneinfo directory on this system.  If load is true, load immediately."
  (let ((zone-sym (if (symbolp zone-name) zone-name (intern zone-name))))
    `(prog1
      (defparameter ,zone-sym (make-timezone :path ,zone-file))
      ,@(when load
              `((realize-timezone ,zone-sym))))))

(defvar *default-timezone*)
(eval-when (:load-toplevel :execute)
  (define-timezone *default-timezone* #p"/etc/localtime"))

(defclass local-time ()
  ((day :accessor day-of :initarg :day :initform 0)
   (sec :accessor sec-of :initarg :sec :initform 0)
   (usec :accessor usec-of :initarg :usec :initform 0)
   (timezone :accessor timezone-of :initarg :timezone
             :initform *default-timezone*)))

(defmacro make-local-time (&rest args)
  `(make-instance 'local-time ,@args))

(defun local-time-day (local-time)
  "Deprecated function to retrieve the day field from the local-time"
  (declare (type local-time local-time))
  (day-of local-time))

(defun local-time-sec (local-time)
  "Deprecated function to retrieve the seconds field from the local-time"
  (declare (type local-time local-time))
  (sec-of local-time))

(defun local-time-msec (local-time)
  "Deprecated function to retrieve the milliseconds field from the local-time"
  (declare (type local-time local-time))
  (floor (usec-of local-time) 1000))

(defparameter +utc-zone+ (make-timezone :subzones '((0 nil "UTC" nil nil))
                                        :loaded t)
  "The zone for Coordinated Universal Time.")

(defun unix-time (local-time)
  "Return the Unix time corresponding to the LOCAL-TIME"
  (+ (* (+ (day-of local-time) 11017) 86400)
     (sec-of local-time)))

(defun timezone (local-time &optional timezone)
  "Return as multiple values the time zone as the number of seconds east of UTC, a boolean daylight-saving-p, the customary abbreviation of the timezone, the starting time of this timezone, and the ending time of this timezone."
  (let* ((zone (realize-timezone
                (or timezone (timezone-of local-time) *default-timezone*)))
         (subzone-idx (or
                       (second (assoc (unix-time local-time)
                                      (timezone-transitions zone)
                                      :test #'>))
                       0))
         (subzone (nth subzone-idx (timezone-subzones zone))))
    (values
     (first subzone)
     (second subzone)
     (third subzone))))

(defun local-time-adjust (source timezone &optional (destination nil))
  "Returns two values, the values of new DAY and SEC slots, or, if DESTINATION is a LOCAL-TIME instance, fills the slots with the new values and returns the destination"
  (realize-timezone (timezone-of source))
  (realize-timezone timezone)
  (let* ((offset-diff (- (timezone source timezone) 
                         (timezone source (timezone-of source))))
         (offset-sign (signum offset-diff)))
    (multiple-value-bind (offset-day offset-sec)
        (floor (abs offset-diff) 86400)
      (let ((new-day (+ (day-of source) (* offset-sign offset-day)))
            (new-sec (+ (sec-of source) (* offset-sign offset-sec))))
        (when (minusp new-sec)
          (incf new-sec 86400)
          (decf new-day))
        (cond
          (destination
           (setf (usec-of destination) (usec-of source)
                 (sec-of destination) new-sec
                 (day-of destination) new-day
                 (timezone-of destination) timezone)
           destination)
          (t
           (values new-day new-sec)))))))

(defun maximize-time-part (local-time)
  "Return a local-time with the time part set to the end of the day."
  (multiple-value-bind (usec sec min hour day month year day-of-week daylight-saving-time-p timezone)
      (decode-local-time local-time)
    (declare (ignore usec sec min hour day-of-week daylight-saving-time-p))
    (encode-local-time 0 59 59 23 day month year timezone)))

(defun minimize-time-part (local-time)
  "Return a local-time with the time part set to the beginning of the day."
  (multiple-value-bind (usec sec min hour day month year day-of-week daylight-saving-time-p timezone)
      (decode-local-time local-time)
    (declare (ignore usec sec min hour day-of-week daylight-saving-time-p))
    (encode-local-time 0 0 0 0 day month year timezone)))

(defun astronomical-julian-date (local-time)
  (- (day-of local-time) +astronomical-julian-date-offset+))

(defun modified-julian-date (local-time)
  (- (day-of local-time) +modified-julian-date-offset+))

(defun local-time-diff (time-a time-b)
  "Returns a new LOCAL-TIME containing the difference between TIME-A and TIME-B"
  (multiple-value-bind (day-a sec-a)
      (local-time-adjust time-a (timezone-of time-b))
      (let ((usec (- (usec-of time-a) (usec-of time-b)))
            (seconds (- sec-a (sec-of time-b)))
            (days (- day-a (day-of time-b))))
        (when (minusp usec)
          (decf seconds)
          (incf usec 1000000))
        (when (minusp seconds)
          (decf days)
          (incf seconds 86400))
        (make-local-time :usec usec
                        :sec seconds
                        :day days))))

(defun local-time-sum (time-a time-b)
  "Returns a new LOCAL-TIME containing the sum of TIME-A and TIME-B"
  (multiple-value-bind (day-a sec-a)
      (local-time-adjust time-a (timezone-of time-b))
    (let ((usec (+ (usec-of time-a) (usec-of time-b)))
          (sec (+ sec-a (sec-of time-b)))
          (day (+ day-a (day-of time-b))))
      (when (> usec 1000000)
        (decf usec 1000000)
        (incf sec))
      (when (> sec 86400)
        (decf sec 86400)
        (incf day))
      (make-local-time :usec usec
                       :sec sec
                       :day day
                       :timezone (timezone-of time-b)))))

(defun local-time-compare (time-a time-b)
  "Returns the symbols <, >, or =, describing the relationship between TIME-A and TIME-b."
  (multiple-value-bind (day-a sec-a)
      (local-time-adjust time-a (timezone-of time-b))
    (cond
      ((< day-a (day-of time-b)) '<)
      ((> day-a (day-of time-b)) '>)
      ((< sec-a (sec-of time-b)) '<)
      ((> sec-a (sec-of time-b)) '>)
      ((< (usec-of time-a) (usec-of time-b)) '<)
      ((> (usec-of time-a) (usec-of time-b)) '>)
      (t                                                     '=))))

(defun month-days (month)
  (aref +month-days+ month))

(defun decode-month (day)
  (position day +month-days+ :from-end t :test #'>=))

(defun local-time-day-of-week (local-time)
  (mod (+ 3 (day-of local-time)) 7))

(defun encode-local-time (us ss mm hh day month year &optional timezone)
  "Return a new LOCAL-TIME instance corresponding to the specified time elements."
  (let* ((int-month (if (< month 3) (+ month 9) (- month 3)))
         (int-year (if (< month 3) (- year 2001) (- year 2000)))
         (zone (realize-timezone (or timezone *default-timezone*)))
         (result (make-local-time
                  :usec us
                  :sec (+ (* hh 3600) (* mm 60) ss)
                  :day (+ (floor (* int-year 1461) 4)
                          (month-days int-month)
                          (1- day))
                  :timezone zone)))
    result
    (local-time-adjust result zone result)))

(defun local-time (&key (universal nil) (internal nil) (unix nil) (usec 0) (timezone nil))
  "Produce a LOCAL-TIME instance from the provided numeric time representation."
  (declare (ignorable internal))
  (cond
    (universal
     (multiple-value-bind (sec minute hour date month year)
         (decode-universal-time universal)
       (encode-local-time usec sec minute hour date month year
                          (realize-timezone (or timezone
                                                *default-timezone*)))))
    (internal
     ;; FIXME: How to portably convert between internal time?
     (error "Conversion of internal time not implemented"))
    (unix
     (let* ((days (floor unix 86400))
            (secs (- unix (* days 86400))))
       (make-local-time :day (- days 11017)
                        :sec secs
                        :usec usec
                        :timezone (realize-timezone
                                   (or timezone *default-timezone*)))))))

(defun now ()
  (local-time :universal (get-universal-time)))

(defun local-time< (time-a time-b)
  "Returns T if TIME-A is less than TIME-B"
  (eql (local-time-compare time-a time-b) '<))

(defun local-time<= (time-a time-b)
  "Returns T if TIME-A is less than or equal to TIME-B"
  (not (null (member (local-time-compare time-a time-b) '(< =)))))

(defun local-time> (time-a time-b)
  "Returns T if TIME-A is greater than TIME-B"
  (eql (local-time-compare time-a time-b) '>))

(defun local-time>= (time-a time-b)
  "Returns T if TIME-A is greater than or equal to TIME-B"
  (not (null (member (local-time-compare time-a time-b) '(> =)))))

(defun local-time= (time-a time-b)
  "Returns T if TIME-A is equal to TIME-B"
  (eql (local-time-compare time-a time-b) '=))

(defun local-time/= (time-a time-b)
  "Returns T if TIME-A is not equal to TIME-B"
  (not (eql (local-time-compare time-a time-b) '=)))

(defun local-time-designator ()
  "Convert a designator (real number) as a LOCAL-TIME instance"
  nil)

(defun local-time-decoded-date (local-time)
  (multiple-value-bind (leap-cycle year-days)
      (floor (day-of local-time) 1461)
    (multiple-value-bind (years month-days)
        (floor year-days 365)
      (let* ((month (decode-month month-days))
             (day (1+ (- month-days (month-days month)))))
        (values
         (+ (* leap-cycle 4)
            years
            (if (>= month 10)
                2001
                2000))
         (if (>= month 10)
             (- month 9)
             (+ month 3))
         day)))))

(defun local-time-decoded-time (local-time)
  (multiple-value-bind (hours hour-remainder)
      (floor (sec-of local-time) 3600)
    (multiple-value-bind (minutes seconds)
        (floor hour-remainder 60)
      (values
       hours
       minutes
       seconds))))

(defparameter +leap-factor+ 1461)

(defun decode-local-time (local-time)
  "Returns the decoded time as multiple values: ms, ss, mm, hh, day, month, year, day-of-week, daylight-saving-time-p, timezone, and the customary timezone abbreviation."
  (multiple-value-bind (hours minutes seconds)
      (local-time-decoded-time local-time)
    (multiple-value-bind (year month day)
        (local-time-decoded-date local-time)
      (values
       (usec-of local-time)
       seconds minutes hours
       day month year
       (local-time-day-of-week local-time)
       (nth-value 1 (timezone local-time))
       (timezone-of local-time)
       (nth-value 2 (timezone local-time))))))

(defun skip-timestring-junk (stream junk-allowed &rest expected)
  (cond
    (junk-allowed
     ;; just skip non-digit characters
     (loop for c = (read-char stream nil nil)
           while (and c (not (digit-char-p c)))
           finally (unread-char c stream)))
    (t
     ;; must have an expected character or the string end, then
     ;; followed by a digit or the string end
     (let ((c (read-char stream nil nil)))
       (unless (or (null c) (member c expected :test 'eql))
         (error
          "Junk in timestring: expected ~:[(or ~{~s~^ ~})~;~{~s~}~], got ~s"
          (= (length expected) 1)
          expected
          c)))
     (let ((c (read-char stream nil nil)))
       (if (or (null c) (digit-char-p c) (member c expected :test 'eql))
           (when c
             (unread-char c stream))
           (error "Junk in timestring: expected digit, got ~s"  c))))))

(defun read-integer-str (stream)
  (loop for c = (read-char stream nil nil)
        while (and c (digit-char-p c))
        collect c into result
        finally (progn
                  (when c
                    (unread-char c stream))
                  (return
                    (when result
                      (parse-integer (coerce result 'string)))))))

(defun read-millisecond-str (stream)
  (loop for c = (read-char stream nil nil)
        while (and c (digit-char-p c))
        collect c into result
        finally (progn
                  (when c
                    (unread-char c stream))
                  (return
                    (when result
                      (* (expt 10 (- 6 (min (length result) 6)))
                         (parse-integer (coerce result 'string)
                                        :end (min (length result) 6))))))))

(defun split-timestring (str &rest args)
  (declare (inline))
  (apply #'%split-timestring (coerce str 'simple-string) args))

(defun %split-timestring (time-string &key (start 0) (end (length time-string))
                                      (fail-on-error t) (time-separator #\:)
                                      (date-separator #\-)
                                      (allow-missing-elements-p nil)
                                      (date-time-separator #\T)
                                      (allow-missing-date-part-p t) (allow-missing-time-part-p t)
                                      (allow-missing-timezone-part-p t))
  "Based on http://www.ietf.org/rfc/rfc3339.txt including the function names used. Returns (values year month day hour minute second offset-hour offset-minute). If the parsing
  fails, then either signals an error or returns nil based on FAIL-ON-ERROR."
  (declare (type character date-time-separator time-separator date-separator)
           (type (simple-array character) time-string)
           (optimize (speed 3)))
  (the list
    (let (year month day hour minute second offset-hour offset-minute)
      (declare (type (or null fixnum) start end year month day hour minute offset-hour offset-minute)
               (type (or null integer float) second))
      (macrolet ((passert (expression)
                   `(unless ,expression
                     (parse-error)))
                 (parse-integer-into (start-end place &optional low-limit high-limit)
                   (let ((entry (gensym "ENTRY"))
                         (value (gensym "VALUE"))
                         (pos (gensym "POS"))
                         (start (gensym "START"))
                         (end (gensym "END")))
                     `(let ((,entry ,start-end))
                       (if ,entry
                           (let ((,start (car ,entry))
                                 (,end (cdr ,entry)))
                             (multiple-value-bind (,value ,pos) (parse-integer time-string :start ,start :end ,end :junk-allowed t)
                               (passert (= ,pos ,end))
                               (setf ,place ,value)
                               ,(if (and low-limit high-limit)
                                    `(passert (<= ,low-limit ,place ,high-limit))
                                    (values))
                               (values)))
                           (passert allow-missing-elements-p)))))
                 (with-parts-and-count ((start end split-chars) &body body)
                   `(multiple-value-bind (parts count) (split ,start ,end ,split-chars)
                     (declare (ignorable count) (type fixnum count)
                      ;;(type #1=(cons (cons fixnum fixnum) (or null #1#)) parts)
                      (type list parts))
                     ,@body)))
        (labels ((split (start end chars)
                   (declare (type fixnum start end))
                   (unless (consp chars)
                     (setf chars (list chars)))
                   (loop with last-match = start
                         with match-count of-type (integer 0 #.most-positive-fixnum) = 0
                         for index of-type fixnum upfrom start
                         while (< index end)
                         for el = (aref time-string index)
                         when (member el chars :test #'char-equal)
                         collect (prog1 (if (< last-match index)
                                            (cons last-match index)
                                            nil)
                                   (incf match-count)
                                   (setf last-match (1+ index)))
                                 into result
                         finally (return (values (if (zerop (- index last-match))
                                                     result
                                                     (prog1
                                                         (nconc result (list (cons last-match index)))
                                                       (incf match-count)))
                                                 match-count))))
                 (parse ()
                   (with-parts-and-count (start end date-time-separator)
                     (cond ((= count 2)
                            (if (first parts)
                                (full-date (first parts))
                                (passert allow-missing-date-part-p))
                            (if (second parts)
                                (full-time (second parts))
                                (passert allow-missing-time-part-p))
                            (done))
                           ((and (= count 1)
                                 allow-missing-date-part-p
                                 (find time-separator time-string
                                       :start (car (first parts))
                                       :end (cdr (first parts))))
                            (full-time (first parts))
                            (done))
                           ((and (= count 1)
                                 allow-missing-time-part-p
                                 (find date-separator time-string
                                       :start (car (first parts))
                                       :end (cdr (first parts))))
                            (full-date (first parts))
                            (done)))
                     (parse-error)))
                 (full-date (start-end)
                   (let ((parts (split (car start-end) (cdr start-end) date-separator)))
                     (passert (eql (list-length parts) 3))
                     (date-fullyear (first parts))
                     (date-month (second parts))
                     (date-mday (third parts))))
                 (date-fullyear (start-end)
                   (parse-integer-into start-end year))
                 (date-month (start-end)
                   (parse-integer-into start-end month 1 12))
                 (date-mday (start-end)
                   (parse-integer-into start-end day 1 31))
                 (full-time (start-end)
                   (let ((start (car start-end))
                         (end (cdr start-end)))
                     (with-parts-and-count (start end (list #\Z #\- #\+))
                       (let ((zulup (find #\Z time-string :test #'char-equal :start start :end end)))
                         (passert (<= 1 count 2))
                         (partial-time (first parts))
                         (if (= count 1)
                             (passert allow-missing-timezone-part-p)
                             (let* ((entry (second parts))
                                    (start (car entry))
                                    (end (cdr entry)))
                               (declare (type fixnum start end))
                               (passert (or zulup
                                            (not (zerop (- end start)))))
                               (if zulup
                                   (setf offset-hour 0
                                         offset-minute 0)
                                   (time-offset (second parts)
                                                (if (find #\+ time-string :test #'char-equal :start start :end end)
                                                    1
                                                    -1)))))))))
                 (partial-time (start-end)
                   (with-parts-and-count ((car start-end) (cdr start-end) time-separator)
                     (passert (eql (list-length parts) 3))
                     (time-hour (first parts))
                     (time-minute (second parts))
                     (time-second (third parts))))
                 (time-hour (start-end)
                   (parse-integer-into start-end hour 0 23))
                 (time-minute (start-end)
                   (parse-integer-into start-end minute 0 59))
                 (time-second (start-end)
                   (let* ((*read-eval* nil)
                          (start (car start-end))
                          (end (cdr start-end))
                          (float (read-from-string (substitute #\, #\. time-string :start start :end end)
                                                   t nil :start start :end end)))
                     (passert (typep float '(or float integer)))
                     (setf second float)))
                 (time-offset (start-end sign)
                   (with-parts-and-count ((car start-end) (cdr start-end) time-separator)
                     (passert (= count 2))
                     (parse-integer-into (first parts) offset-hour 0 23)
                     (parse-integer-into (second parts) offset-minute 0 59)
                     (setf offset-hour (* offset-hour sign)
                           offset-minute (* offset-minute sign))))
                 (parse-error ()
                   (if fail-on-error
                       (error "Failed to parse ~S as an rfc3339 time" time-string)
                       (return-from %split-timestring nil)))
                 (done ()
                   (return-from %split-timestring (list year month day hour minute second offset-hour offset-minute))))
          (parse))))))

(defun parse-rfc3339-timestring (timestring &key (fail-on-error t) &allow-other-keys)
  (apply #'parse-timestring timestring :fail-on-error fail-on-error
         :allow-missing-timezone-part-p nil :allow-missing-elements-p nil
         :allow-missing-time-part-p nil :allow-missing-date-part-p nil))

(defun parse-timestring (timestring &rest args)
  "Parse a timestring and return the corresponding LOCAL-TIME. See split-timestring for details."
  (destructuring-bind (year month day hour minute second offset-hour offset-minute)
      (apply #'split-timestring timestring args)
    ;; TODO should we assert on month and leap rules here?
    (let ((usec 0)
          (timezone *default-timezone*))
      (when (and offset-hour offset-minute)
        (if (and (zerop offset-hour) (zerop offset-minute))
            (setf timezone +utc-zone+)
            (progn
              ;; TODO process timezone offsets
              )))
      (unless (typep second 'integer)
        ;; TODO extract usec
        )
      ;; we don't care about usec defaulting, it's optional
      (unless (and year month day hour minute second)
        (multiple-value-bind (now-usec now-second now-minute now-hour now-day now-month now-year)
            (decode-local-time (now))
          (declare (ignore now-usec))
          (unless second (setf second now-second))
          (unless minute (setf minute now-minute))
          (unless hour (setf hour now-hour))
          (unless day (setf day now-day))
          (unless month (setf month now-month))
          (unless year (setf year now-year))))
      (encode-local-time usec second minute hour day month year *default-timezone*))))

(defun format-rfc3339-timestring (local-time)
  (format-timestring local-time))

(defun format-timestring (local-time &key destination timezone omit-timezone-p
                                     (use-zulu-p t)
                                     (date-elements 3) (time-elements 4)
                                     (date-separator #\-) (time-separator #\:)
                                     (date-time-separator #\T))
  "Produces on stream the timestring corresponding to the LOCAL-TIME with the given options. If DESTINATION is NIL, returns a string containing what would have been output.  If DESTINATION is T, prints the string to *standard-output*."
  (declare (type (or null stream) destination)
           (type (integer 0 3) date-elements)
           (type (integer 0 4) time-elements))
  (let ((str (with-output-to-string (str)
               (when timezone
                 (setf local-time (local-time-adjust local-time timezone (make-local-time))))
               (multiple-value-bind (usec sec minute hour day month year day-of-week daylight-p zone)
                   (decode-local-time local-time)
                 (declare (ignore day-of-week daylight-p))
                 (cond
                   ((> date-elements 2)
                    (format str "~:[~;-~]~4,'0d~c"
                            (minusp year)
                            (abs year)
                            date-separator))
                   ((plusp date-elements)
                    ;; if the year is not shown, but other parts of the date are,
                    ;; the year is replaced with a hyphen
                    (princ "-" str)))
                 (when (> date-elements 1)
                   (format str "~2,'0d~c" month date-separator))
                 (when (> date-elements 0)
                   (format str "~2,'0d" day))
                 (when (and (plusp date-elements) (plusp time-elements))
                   (princ date-time-separator str))
                 (when (> time-elements 0)
                   (format str "~2,'0d" hour))
                 (when (> time-elements 1)
                   (format str "~c~2,'0d" time-separator minute))
                 (when (> time-elements 2)
                   (format str "~c~2,'0d" time-separator sec))
                 (when (and (> time-elements 3)
                            (not (zerop usec)))
                   (format str ".~6,'0d" usec))
                 (unless omit-timezone-p
                   (let* ((offset (local-timezone local-time zone)))
                     (if (and use-zulu-p
                              (eq zone +utc-zone+))
                         (princ #\Z str)
                         (format str "~c~2,'0d~c~2,'0d"
                                 (if (minusp offset) #\- #\+)
                                 (floor offset 3600)
                                 time-separator
                                 (abs (mod offset 3600))))))))))
    (when destination
      (princ str destination))
    str))

(defun universal-time (local-time)
  "Return the UNIVERSAL-TIME corresponding to the LOCAL-TIME"
  (multiple-value-bind (usec seconds minutes hours day month year)
      (decode-local-time local-time)
    (declare (ignore usec))
    (encode-universal-time seconds minutes hours day month year)))

(defun internal-time (local-time)
  "Return the internal system time corresponding to the LOCAL-TIME"
  ;; FIXME: How to portably convert between internal and local time?
  (declare (ignorable local-time))
  (error "Not implemented"))

(defun local-timezone (adjusted-local-time
                       &optional (timezone *default-timezone*))
  "Return the local timezone adjustment applicable at the already adjusted-local-time.  Used to reverse the effect of TIMEZONE and LOCAL-TIME-ADJUST."
  (let* ((unix-time (unix-time adjusted-local-time))
         (subzone-idx (or
                       (second (find-if
                                (lambda (tuple)
                                  (> unix-time
                                     (- (first tuple)
                                        (first
                                         (nth (second tuple)
                                              (timezone-subzones timezone))))))
                                (timezone-transitions timezone)))
                       0)))
    (first (nth subzone-idx (timezone-subzones timezone)))))

(defun read-timestring (stream char)
  (declare (ignore char))
  (parse-timestring
   (with-output-to-string (str)
     (loop for c = (read-char stream nil #\space)
           until (or (eql c #\space) (eql c #\)))
           do (princ c str)
           finally (unread-char c stream)))))

(defun read-universal-time (stream char arg)
  (declare (ignore char arg))
  (local-time :universal
              (parse-integer
               (with-output-to-string (str)
                 (loop for c = (read-char stream nil #\space)
                       while (digit-char-p c)
                       do (princ c str)
                       finally (unread-char c stream))))))

(defun enable-read-macros ()
  (set-macro-character #\@ 'read-timestring)
  (set-dispatch-macro-character #\# #\@ 'read-universal-time)
  (values))

(defmethod print-object ((object local-time) stream)
  "Print the LOCAL-TIME object using the standard reader notation"
  (when *print-escape*
    (princ "@" stream))
  (format-timestring object :destination stream))

(defmethod print-object ((object timezone) stream)
  "Print the TIMEZONE object in a reader-rejected manner."
  (format stream "#<TIMEZONE: ~:[UNLOADED~;~{~a~^ ~}~]>"
          (timezone-loaded object)
          (mapcar #'third (timezone-subzones object))))