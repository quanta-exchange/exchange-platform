ALTER TABLE accounts
ADD CONSTRAINT uq_accounts_account_currency
UNIQUE (account_id, currency);

ALTER TABLE ledger_postings
ADD CONSTRAINT fk_ledger_postings_account_currency
FOREIGN KEY (account_id, currency) REFERENCES accounts(account_id, currency);
