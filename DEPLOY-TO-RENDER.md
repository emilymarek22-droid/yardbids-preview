# Publish a private YardBids preview

This creates a testing link. It is not ready for a public launch yet because the current data file is temporary. Before launch, YardBids needs a production database, secure login, payment webhooks, and a safety review.

## 1. Create a private GitHub repository

1. Create or sign in to GitHub.
2. Select **New repository**.
3. Name it `yardbids-preview`.
4. Choose **Private**.
5. Create the repository.
6. Upload the contents of this `yardbids-real-app` folder.

Do **not** upload `stripe-test.env`. It contains your private Stripe key.

## 2. Create a Render web service

1. Create or sign in to Render.
2. Select **New** then **Web Service**.
3. Connect GitHub and select the private `yardbids-preview` repository.
4. Choose **Node** for the language.
5. Use `npm install` as the build command.
6. Use `npm start` as the start command.
7. Deploy the service.

Render provides an `onrender.com` preview link when the deploy finishes.

## 3. Add Stripe only after the preview works

In Render, open the service's Environment page and add:

- `STRIPE_SECRET_KEY` — your private `sk_test_...` key
- `STRIPE_MODE` — `test`

Never place Stripe keys in GitHub or in a public file.
