# Bexter Pharmaceuticals OMS

## Important deployment notes
The app uses the existing Supabase project configuration in `config.js`. Keep the publishable key public; never put a `service_role` or secret key in browser code.

## One-time database fix
1. Open Supabase → SQL Editor.
2. Open `0002_order_submission_fix.sql` from this repository and copy all its SQL.
3. Paste it into a new SQL query and press **Run** once.
4. This adds the customer and doctor fields required by the current Order form and updates the `submit_order` RPC.

## Publish
Commit the updated files to the repository's `main` branch (root folder).
The GitHub Pages project URL is:
https://bexter-pharma.github.io/bexter-pharmaceuticals/

## Role behavior
- Admin: Dashboard, Orders, Products, Inventory, Approvals, Reports.
- Sales Manager: Dashboard, Orders, Approvals, Reports.
- MR / Distributor: Dashboard, Orders, New Order, Reports.

New Order is intentionally hidden for Admin and Sales Manager because the database only permits MR / Distributor accounts to submit orders. Admin approves the final stage; Sales Manager approves the first stage.
