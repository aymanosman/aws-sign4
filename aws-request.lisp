(defparameter +iso-8601-basic-format+
  '((:year 4) (:month 2) (:day 2) #\T
    (:hour 2) (:min 2) (:sec 2) 
    :gmt-offset-or-z))

(defvar *swf-endpoints* 
  '((:us-east-1 . "swf.us-east-1.amazonaws.com")
    (:us-west-1 . "swf.us-west-1.amazonaws.com")
    (:us-west-2 . "swf.us-west-2.amazonaws.com")
    (:eu-west-1 . "swf.eu-west-1.amazonaws.com")))

(defvar *credentials* nil)

(defun file-credentials (file)
  (with-open-file (str file)
    (list (read-line str) (read-line str))))

(defun initialize (credentials)
  (setf *credentials* credentials))

(defun url-encode (string &key (external-format :utf-8)
                               (escape t))
  "URL-encodes a string using the external format EXTERNAL-FORMAT."
  (with-output-to-string (s)
    (loop for c across string
          for index from 0
          do (cond ((or (char<= #\0 c #\9)
                        (char<= #\a c #\z)
                        (char<= #\A c #\Z)
                        ;; note that there's no comma in there - because of cookies
                        (find c "-_.~" :test #'char=))
                    (write-char c s))
                   ((and (not escape)
                         (char= #\% c))
                    (write-char c s))
                   (t (loop for octet across 
                           (string-to-octets string
                                             :start index
                                             :end (1+ index)
                                             :external-format external-format)
                         do (format s "%~2,'0x" octet)))))))

(defun create-canonical-path (path)
  (labels ((helper (rest)
             (cond 
               ((null rest) nil)
               ((string= (car rest) "..")
                (helper (cdr (helper (cdr rest)))))
               ((string= (car rest) ".")
                (helper (cdr rest)))
               (t (cons (car rest)
                        (helper (cdr rest)))))))
    (let* ((splitted
            (loop for x on 
                 (cdr
                  (split-sequence:split-sequence #\/ path))
               unless (and (string= (car x) "")
                           (cdr x))
               collect (car x)))
          (res (reverse 
                (helper
                 (reverse splitted)))))
      (format nil "/~{~A~^/~}" 
               (mapcar (lambda (x)
                         (url-encode 
                          x
                          :external-format :latin-1
                          :escape nil))
                       res)))))
(defun merge-duplicates* (list)
  (when list
    (let* ((rest (merge-duplicates (cdr list)))
           (nextkey (caar rest))
           (nextval (cdar rest))
           (key (caar list))
           (val (cdar list)))
      (if (equalp nextkey key)
          (cons 
           (progn
             (cons key 
                   (append nextval val)))
           (cdr rest))
          (cons (cons key val)
                rest)))))


(defun merge-duplicates (list)
  (reverse (merge-duplicates* (reverse list))))


(defun create-canonical-request (request-method path params headers payload)
  (labels ((getkey (v &optional (car nil))
             (when car
               (setf v (car v)))
             (when (symbolp v)
               (setf v (symbol-name v)))
             (string-downcase v))
           (signed-headers (str &optional (newline t))
             (prog1
                 (format str "~{~A~^;~}" 
                         (remove-duplicates (sort (copy-list (loop for x in headers
                                                                collect (getkey x t)))
                                                  #'string<)
                                            :test #'equalp))
               (when newline
                 (write-line "" str)))
             ))
    (values
     (with-output-to-string (str)
       (format str "~A~%" (ecase request-method 
                            (:get "GET") 
                            (:post "POST")))
       (format str "~A~%" (create-canonical-path path))
       (loop for  x on (sort (copy-list params) #'string< :key (lambda (x) 
                                                                 (format nil "~S~S"
                                                                         (getkey x t)
                                                                         (cdr x)
                                                                         )))
          for (key value) = (car x)
          do (format str "~A=~A~A" 
                     (url-encode key)
                     (url-encode value)
                     (if (cdr x)
                         "&" "")))
       (format str "~%")
       (loop for  x on (merge-duplicates (sort (copy-list headers) #'string< :key (lambda (x) (getkey x t))))
          for (key . value) = (car x)
          do (format str "~A:~{~A~^,~}~%" 
                     (hunchentoot:url-encode (getkey key))
                     (loop for x in (sort (copy-list value) #'string<)
                        collect (string-trim " " x))
                     ))
       (write-line "" str)
       (signed-headers str)
       (write-string (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha256 payload)) str))
     (signed-headers nil nil)
     )))

(defvar *timezonereg-read* nil)

(defun string-to-sign (canonical-request request-date credential)
  (unless *timezonereg-read*
    (local-time::reread-timezone-repository)
    (setf *timezonereg-read* t))
  (let ((credential-scope
         (subseq credential (1+ (position #\/ credential)))))
    (with-output-to-string (str)
      (format str "AWS4-HMAC-SHA256~%")
      (local-time:format-timestring str 
                                    (if (stringp request-date)
                                        (local-time:universal-to-timestamp 
                                         (net.telent.date:parse-time request-date))
                                        request-date)
                                    :format +iso-8601-basic-format+
                                    :timezone (local-time:find-timezone-by-location-name "GMT"))
      (write-line "" str)
      (write-line credential-scope str)
      (write-string (ironclad:byte-array-to-hex-string 
                     (ironclad:digest-sequence 
                      :sha256
                      (sb-ext:string-to-octets canonical-request 
                                               :external-format :utf-8)))
                    str))))

(defun calculate-derived-key (secret-key date region service)
  (labels ((calculate-hmac-digest (key val)
             (let ((hmac
                    (ironclad:make-hmac key :sha256)))
               (ironclad:update-hmac hmac val)
               (ironclad:hmac-digest hmac))))
    (calculate-hmac-digest
     (calculate-hmac-digest
      (calculate-hmac-digest
       (calculate-hmac-digest 
        (sb-ext:string-to-octets (format nil "AWS4~A" secret-key))
        (sb-ext:string-to-octets 
         (if (stringp date)
             date
             (local-time:format-timestring nil date :format +iso-8601-basic-format+))))
       (sb-ext:string-to-octets region))
      (sb-ext:string-to-octets service))
     (sb-ext:string-to-octets "aws4_request"))))

(defun calculate-signature (key string-to-sign credential)
  (labels ((calculate-hmac-digest (key val)
             (let ((hmac
                    (ironclad:make-hmac key :sha256)))
               (ironclad:update-hmac hmac val)
               (ironclad:hmac-digest hmac))))
    (destructuring-bind (ign date region service ign2)
        (split-sequence:split-sequence 
         #\/ credential)
      (declare (ignore ign ign2))
      (calculate-hmac-digest
       (calculate-derived-key key date region service)
       (sb-ext:string-to-octets string-to-sign :external-format :utf-8)))))

(defun authorization-header (key credential request-method path params headers payload &optional date)
  (multiple-value-bind (creq singed-headers)
      (create-canonical-request 
                request-method path params headers
                (sb-ext:string-to-octets  payload :external-format :utf-8))
    (let* ((sts (string-to-sign 
                 creq 
                 (or date
                     (cadr (assoc "Date" headers :test #'equalp))
                     (cadr (assoc "X-Amz-Date" headers :test #'equalp)))
                 credential))
           (signature 
            (calculate-signature 
             key
             sts
             credential)))
      (values
       (format nil 
               "AWS4-HMAC-SHA256 Credential=~A, SignedHeaders=~A, Signature=~A"
               credential
               singed-headers
               (ironclad:byte-array-to-hex-string  signature))
       creq
       sts))))


(defun aws-request2 (endpoint path x-amz-target content-type payload)
  (check-type endpoint (member :us-east-1 :us-west-1 :us-west-2 :eu-west-1))
  (let* ((dateobj (local-time:now)) 
         (date (local-time:format-rfc1123-timestring 
                nil dateobj))
         (additional-headers
          (list (cons "x-amz-target" x-amz-target)
                (cons "Date" date)
                (cons "x-amz-date"
                      (local-time:format-timestring 
                       nil dateobj
                       :format +iso-8601-basic-format+
                       :timezone local-time:+utc-zone+)))))
    (unless *credentials*
      (error "AWS credentials missing"))
    (multiple-value-bind (authorization-header creq sts)
        (common-lisp-user::authorization-header 
         (cadr *credentials*)
         (format nil
                 "~A/~A/~A/swf/aws4_request"
                 (car *credentials*)
                 (local-time:format-timestring 
                  nil dateobj
                  :format '((:YEAR 4) (:MONTH 2) (:DAY 2)))
                 (string-downcase (symbol-name endpoint))
                 )
         :post 
         path
         nil
         (append `(( "host" ,(cdr (assoc endpoint *swf-endpoints*)))
                   ("Content-Type" ,content-type))
                 (loop for x in additional-headers
                    collect (list (car x) (cdr x))))
         payload
         dateobj)
      (declare (ignore creq sts))
      (push 
       (cons "Authorization"
             authorization-header)
       additional-headers)
      (multiple-value-bind (body status-code)
          (drakma:http-request 
           (format nil "http://~A~A" (cdr (assoc endpoint *swf-endpoints*)) path) 
           :method :post 
           :additional-headers additional-headers
           :content payload
           :content-type content-type)
        (values
         (when body
           (sb-ext:octets-to-string 
            body))
         status-code
                                        ;creq 
                                        ;sts
         )))))


(initialize (file-credentials "~/.aws"))
