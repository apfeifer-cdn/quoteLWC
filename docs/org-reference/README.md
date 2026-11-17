# Org reference metadata

Retrieved from the org for reference only. Nothing here is deployed: this folder is outside
the SFDX project (`quoteLWC/`). The quote tool uses no Contact fields.

## web-store-estimator/

The web store (Experience Cloud) product estimator: `ProductEstimatorController`, the
`productEstimator` LWC and `Contact.ContactOwnerEmail__c`. It is separate from the quote tool
and was moved out of the SFDX project so quote deploys no longer redeploy it. Removing it
from the project does not remove it from the org; the web store keeps working.

`ContactOwnerEmail__c` (formula `Owner.Email`) lets a logged-in store user's estimate PDF show
their account rep's email; store users cannot read internal User records directly. Deleting the
field from the org requires removing its use in `ProductEstimatorController.generatePDF` first,
or that class will no longer compile.
