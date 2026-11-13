# Quote tool (SFDX project)

This folder is the SFDX project root. Run every `sf` command from here.

```
quoteLWC/
  sfdx-project.json        source API 62.0, one package directory
  .forceignore             keeps the reference profile and standard fields out of deploys
  force-app/main/default/  classes, lwc, objects, pages, flows, customMetadata, permissionsets
../docs/costing/           costing workbooks, the Product2 export, and data load files
```

## Quote V2: estimated LDP and margin

### Formula

```
base FOB = Blank FOB (base style)
         + Decoration Cost, main location (main decoration)
         + Decoration Cost, additional location (each additional decoration;
           falls back to the main location cost, with a warning, when blank)
tier FOB = base FOB with the manufacturer upcharge for the quantity
LDP      = tier FOB x (1 + duty% + MPF% + insurance% + finance%)
         + broker + freight + warehouse + marketing + compliance
GM%      = 1 - LDP / sell price
```

Mexico Quick Turn today: `LDP = tier FOB x 1.045 + 0.10`.

### Where the numbers live

| Data | Location |
| --- | --- |
| Blank FOB | `Product2.Blank_FOB__c` on the base style (`Estimator__c = Product`) |
| Decoration cost | `Product2.Main_Decoration_Cost__c` and `Product2.Additional_Location_Cost__c` on the decoration product |
| Percent and per-piece charges | nine `mfg__c` fields labelled "LDP ..." |
| Small-quantity upcharges | `Manufacturer_Upcharge__c` rows under the manufacturer (range, Multiplier or Dollar, value) |
| Saved quote description | `Product2.Description` (standard field, replaced with the text typed in the wizard) |
| Per-line audit snapshot | `QuoteLineItem.Cost_Snapshot__c` (JSON, never read by the PDF pages) |

The manufacturer used is the quoted product's `Manufacturer__c` (or the one picked on the decision screen).

### Apex contract

`QuoteProductController.getQuickTurnCosts(estimatorProductId, mainDecorationId, additionalDecorationIds, manufacturerId, quantities)`
returns:

```json
{
  "available": true,
  "message": null,
  "warnings": ["No cost on file for UPC Sticker; it is counted as $0."],
  "manufacturerId": "a0B...",
  "manufacturerName": "MLMX QT",
  "baseFob": 6.9737,
  "percentCharges": 0.045,
  "fixedCharges": 0.10,
  "lines": [{ "label": "Blank 1100PR", "cost": 6.2737 }, { "label": "Flat Embroidery", "cost": 0.70 }],
  "tiers": [{ "quantity": 144, "upchargeType": "Multiplier", "upchargeValue": 1.2, "fob": 8.3684, "ldp": 8.8450 }]
}
```

When cost data is missing, `available` is `false` and `message` says what to fix. The wizard
keeps working without a cost.

### Product types

| Type | How it is identified | Sell price | Air |
| --- | --- | --- | --- |
| Quick Turn | `Special_Program_SAP__c` contains "quick" | Authenticated list price, editable | hidden |
| North American Custom | `ProductCode` ends in `MCCUST00` | tier LDP / (1 - account base margin), editable | hidden |
| Everything else | | unchanged | unchanged |

## Deploy

1. Validate first, running the two test classes:

```bash
sf project deploy validate --source-dir force-app --test-level RunSpecifiedTests --tests QuoteProductControllerTest --tests QuoteCostServiceTest --target-org <alias>
```

2. Deploy with the same flags using `sf project deploy start`.
3. Assign the `Quote_Cost_Data_Admin` permission set to whoever maintains costs.
   Reps need no new permission: the wizard reads costs through `QuoteProductController`.
4. Load data (files in `../docs/costing/load/`), in this order:
   1. On the Mexico Quick Turn `mfg__c` record set insurance 1.5, finance 3, duty 0, MPF 0,
      broker 0.01, freight 0.05, warehouse 0.01, marketing 0.02, compliance 0.01.
   2. `manufacturer_upcharges.csv` (insert; replace the placeholder with that record's Id).
   3. `blank_fob.csv` (update Product2 by Id).
   4. `decoration_costs.csv` (update Product2 by Id; map only `Main_Decoration_Cost__c` and
      `Additional_Location_Cost__c`).

The Ids in `blank_fob.csv` and `decoration_costs.csv` are sandbox Ids. Before loading
production, replace them with production Ids matched on `ProductCode`.

The deploy only adds fields, one object, one permission set and code. It is safe to re-run.

## Rollback

Code: redeploy the previous commit of `classes/`, `lwc/` and `pages/`. The new fields and the
`Manufacturer_Upcharge__c` object can stay in the org; nothing reads them once the old code is
back. Data: the loads only fill new fields, so there is nothing to restore.
