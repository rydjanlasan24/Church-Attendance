CHURCH ONLINE ATTENDANCE SYSTEM — UPDATED

Files:
- index.html: website interface, registration, admin area, and QR-image self-check-in
- database.sql: database schema and RPCs

Supabase setup / update:
1) In your Supabase SQL Editor, run the database.sql file. If the tables are already created, running the script is intended to update/create the functions and policies as well.
2) Create admin account(s) in Supabase Authentication.
3) Deploy index.html to a static host (HTTPS required for camera scanning; QR-image upload itself is file-based).

NEW: Members may upload an image of their member QR code on the public registration page. This calls member_self_checkin and records the check-in timestamp. The attendance session name is Member self check-in and the date is Philippine-local date.

SECURITY NOTICE: This public check-in function accepts a member ID from a QR image. Anyone who has or copies another member's QR could potentially check that member in. Consider a unique, secret check-in token per member or event-specific QR codes before production use.

Admin permissions and policies are still a starter implementation and should be reviewed before publishing. Never use a Supabase service-role key in browser code.
