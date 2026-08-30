<?php
// Direct permanent file URLs are disabled. Downloads must use a short-lived token from access.php.
http_response_code(403);
header('Cache-Control: no-store');
exit('Forbidden');
