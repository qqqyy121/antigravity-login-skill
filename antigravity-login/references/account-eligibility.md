# Account eligibility and callback checks

Read this when the client reports account ineligibility or the browser's authentication success does not complete the client login. Check the current official pages before making claims about product access or processing times.

- [Antigravity FAQ](https://antigravity.google/docs/faq): personal-account, age and supported-region requirements. Its regional guidance asks users to inspect the country shown in Google Terms of Service.
- [Google Terms of Service](https://policies.google.com/terms): sign in with the intended account and inspect its country version. Check the active account; an explicitly selected country version or a logged-out page is not sufficient account evidence.
- [Google country association FAQ](https://policies.google.com/faq): account country can depend on creation location and usual access history; VPNs can affect location recognition. A current US proxy exit does not prove that the account is associated with the US. The FAQ's approximate one-year migration update is not the processing time for a manual request.
- [Official country association request](https://policies.google.com/country-association-form): for correcting an inaccurate association. Use the user's actual circumstances. Submission, approval and the client's later eligibility check are separate stages. Do not invent residence details or promise an approval time.
- [Google One family sharing](https://support.google.com/googleone/answer/9004015): consult current rules for shared AI benefits and country requirements. Family-plan membership does not establish that every account meets Antigravity's access conditions.

If network access is verified and the client reproducibly rejects the account's region, stop proxy cycling. Confirm the actual account, country, age requirements and current supported regions. When these appear valid but the refusal persists, preserve the non-sensitive error and use official support. Do not label the refusal as a ban or automated fraud detection without evidence.

Never present `Google authentication succeeded` or `started_with_proxy` as a completed client login. If the browser completed authentication but the client is still waiting, inspect the current local callback flow and preserve `NO_PROXY` for loopback before starting another authentication attempt. Do not replay or share OAuth callbacks.
