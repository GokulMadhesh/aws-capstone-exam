
<?php
$conn = mysqli_connect("streamline-db.cr4sgk8ywx1u.us-east-1.rds.amazonaws.com", "admin", "Password123!", "mysql");

if ($conn) {
    echo "Database Connected Successfully";
} else {
    echo "Database Connection Failed";
}
?>
