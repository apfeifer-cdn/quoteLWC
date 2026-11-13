/**
 * Estimates landed duty paid (LDP) cost per quantity tier for a decorated base style.
 *
 *   base FOB  = Product2.Blank_FOB__c (base style)
 *             + Product2.Decoration_Cost__c (main decoration)
 *             + Additional_Location_Cost__c of each additional decoration
 *               (falls back to Decoration_Cost__c, with a warning, when blank)
 *   tier FOB  = base FOB with the manufacturer's upcharge for the quantity
 *               (Manufacturer_Upcharge__c: Multiplier or Dollar)
 *   LDP       = tier FOB * (1 + duty + MPF + insurance + finance)
 *             + broker + freight + warehouse + marketing + compliance
 *
 * Rates and per-piece charges come from the mfg__c record.
 *
 * The service never throws for missing cost data. It returns available = false with a
 * message so the quote wizard can keep working and show the user what to fix.
 *
 * Complexity: three queries per call regardless of input size; the tier loop is
 * O(Q * U) for Q quantities and U upcharge rows (both bounded, U is a handful of rows).
 */
public with sharing class QuoteCostService {

    public static final String UPCHARGE_MULTIPLIER = 'Multiplier';
    public static final String UPCHARGE_DOLLAR = 'Dollar';
    public static final String NA_CUSTOM_SUFFIX = 'MCCUST00';

    @TestVisible private static final Integer MAX_QUANTITIES = 50;
    @TestVisible private static final Integer MAX_ADDITIONAL_DECORATIONS = 25;
    private static final Integer COST_SCALE = 4;

    public class CostLine {
        @AuraEnabled public String label;
        @AuraEnabled public Decimal cost;
    }

    public class TierCost {
        @AuraEnabled public Integer quantity;
        @AuraEnabled public String upchargeType;   // Multiplier | Dollar | null when no upcharge applies
        @AuraEnabled public Decimal upchargeValue;
        @AuraEnabled public Decimal fob;           // base FOB after the upcharge
        @AuraEnabled public Decimal ldp;
    }

    public class CostResult {
        @AuraEnabled public Boolean available = false;
        @AuraEnabled public String message;                       // why the cost is unavailable
        @AuraEnabled public List<String> warnings = new List<String>();
        @AuraEnabled public Id manufacturerId;
        @AuraEnabled public String manufacturerName;
        @AuraEnabled public Decimal baseFob;                      // blank + all decorations, before upcharge
        @AuraEnabled public Decimal percentCharges;               // sum of the percent rates, as a fraction
        @AuraEnabled public Decimal fixedCharges;                 // sum of the per-piece charges
        @AuraEnabled public List<CostLine> lines = new List<CostLine>();
        @AuraEnabled public List<TierCost> tiers = new List<TierCost>();
    }

    /** Percent rates (as fractions, 0.03 for 3%) and per-piece charges for one manufacturer. */
    public class Charges {
        public Decimal percentTotal = 0;
        public Decimal fixedTotal = 0;
    }

    /**
     * North American Custom products are identified by a SKU ending in MCCUST00. They are
     * costed like Quick Turn products and never show air pricing.
     */
    public static Boolean isNorthAmericanCustom(String productCode) {
        return String.isNotBlank(productCode)
            && productCode.trim().toUpperCase().endsWith(NA_CUSTOM_SUFFIX);
    }

    public static Boolean isQuickProgram(String specialProgram) {
        return specialProgram != null && specialProgram.toLowerCase().contains('quick');
    }

    public static CostResult calculate(Id estimatorProductId, Id mainDecorationId,
            List<String> additionalDecorationIds, Id manufacturerId, List<Integer> quantities) {
        CostResult result = new CostResult();

        if (estimatorProductId == null || mainDecorationId == null) {
            result.message = 'Select a base style and a main decoration to estimate cost.';
            return result;
        }
        if (manufacturerId == null) {
            result.message = 'This product has no manufacturer, so LDP cannot be estimated.';
            return result;
        }
        List<Integer> cleanQuantities = cleanQuantities(quantities);
        if (cleanQuantities.isEmpty()) {
            result.message = 'No quantity tiers were supplied.';
            return result;
        }

        List<Id> additionalIds = new List<Id>();
        for (String raw : additionalDecorationIds == null ? new List<String>() : additionalDecorationIds) {
            if (String.isBlank(raw)) {
                continue;
            }
            if (!(raw instanceof Id)) {
                result.message = 'An additional decoration id is not valid.';
                return result;
            }
            additionalIds.add((Id) raw);
        }
        if (additionalIds.size() > MAX_ADDITIONAL_DECORATIONS) {
            result.message = 'Too many additional decorations (limit ' + MAX_ADDITIONAL_DECORATIONS + ').';
            return result;
        }

        Set<Id> productIds = new Set<Id>{ estimatorProductId, mainDecorationId };
        productIds.addAll(additionalIds);
        Map<Id, Product2> products = new Map<Id, Product2>([
            SELECT Id, Name, ProductCode, Blank_FOB__c, Decoration_Cost__c, Additional_Location_Cost__c
            FROM Product2
            WHERE Id IN :productIds
        ]);

        Product2 baseStyle = products.get(estimatorProductId);
        if (baseStyle == null) {
            result.message = 'Base style not found.';
            return result;
        }
        if (baseStyle.Blank_FOB__c == null) {
            result.message = 'Blank FOB is not set on base style ' + displayName(baseStyle) + '.';
            return result;
        }
        Product2 mainDecoration = products.get(mainDecorationId);
        if (mainDecoration == null) {
            result.message = 'Main decoration not found.';
            return result;
        }
        if (mainDecoration.Decoration_Cost__c == null) {
            result.message = 'Decoration cost is not set on ' + mainDecoration.Name + '.';
            return result;
        }

        List<mfg__c> manufacturers = [
            SELECT Id, Name,
                   Duty_Rate__c, MPF_Rate__c, Insurance_Rate__c, Finance_Rate__c,
                   Broker_Fee__c, Freight__c, WH_HDL__c, Marketing_Fee__c, Compliance_Fee__c,
                   (SELECT Quantity_Lower_Bound__c, Quantity_Upper_Bound__c, Upcharge_Type__c, Value__c
                    FROM Upcharges__r
                    ORDER BY Quantity_Lower_Bound__c DESC)
            FROM mfg__c
            WHERE Id = :manufacturerId
            LIMIT 1
        ];
        if (manufacturers.isEmpty()) {
            result.message = 'Manufacturer not found.';
            return result;
        }
        mfg__c manufacturer = manufacturers[0];
        result.manufacturerId = manufacturer.Id;
        result.manufacturerName = manufacturer.Name;

        if (!hasAnyCharge(manufacturer)) {
            result.message = 'Manufacturer ' + manufacturer.Name
                + ' has no LDP charges set, so LDP cannot be estimated.';
            return result;
        }
        Charges charges = toCharges(manufacturer);

        Decimal baseFob = baseStyle.Blank_FOB__c;
        result.lines.add(line('Blank ' + displayName(baseStyle), baseStyle.Blank_FOB__c));

        baseFob += mainDecoration.Decoration_Cost__c;
        result.lines.add(line(mainDecoration.Name, mainDecoration.Decoration_Cost__c));

        for (Id additionalId : additionalIds) {
            Product2 decoration = products.get(additionalId);
            if (decoration == null) {
                result.warnings.add('An additional decoration was not found and was left out of the cost.');
                continue;
            }
            Decimal cost = decoration.Additional_Location_Cost__c;
            if (cost == null && decoration.Decoration_Cost__c != null) {
                // A blank additional-location cost means the decoration is not offered as an
                // additional location. Cost it at the main-location rate and tell the user.
                cost = decoration.Decoration_Cost__c;
                result.warnings.add(decoration.Name
                    + ' has no additional-location cost; its main-location cost was used.');
            }
            if (cost == null) {
                result.warnings.add('No cost on file for ' + decoration.Name + '; it is counted as $0.');
                cost = 0;
            }
            baseFob += cost;
            result.lines.add(line(decoration.Name + ' (additional)', cost));
        }

        result.baseFob = baseFob.setScale(COST_SCALE, RoundingMode.HALF_UP);
        result.percentCharges = charges.percentTotal;
        result.fixedCharges = charges.fixedTotal;

        for (Integer quantity : cleanQuantities) {
            TierCost tier = new TierCost();
            tier.quantity = quantity;
            Manufacturer_Upcharge__c upcharge = findUpcharge(manufacturer.Upcharges__r, quantity);
            if (upcharge != null) {
                tier.upchargeType = upcharge.Upcharge_Type__c;
                tier.upchargeValue = upcharge.Value__c;
            }
            tier.fob = applyUpcharge(baseFob, tier.upchargeType, tier.upchargeValue);
            tier.ldp = computeLdp(tier.fob, charges);
            result.tiers.add(tier);
        }

        result.available = true;
        return result;
    }

    /** FOB after a manufacturer upcharge. Unknown or missing upcharges leave FOB unchanged. */
    public static Decimal applyUpcharge(Decimal fob, String upchargeType, Decimal upchargeValue) {
        if (fob == null) {
            return null;
        }
        Decimal adjusted = fob;
        if (upchargeValue != null) {
            if (upchargeType == UPCHARGE_MULTIPLIER && upchargeValue > 0) {
                adjusted = fob * upchargeValue;
            } else if (upchargeType == UPCHARGE_DOLLAR) {
                adjusted = fob + upchargeValue;
            }
        }
        return adjusted.setScale(COST_SCALE, RoundingMode.HALF_UP);
    }

    public static Decimal computeLdp(Decimal fob, Charges charges) {
        if (fob == null || charges == null) {
            return null;
        }
        Decimal ldp = fob * (1 + charges.percentTotal) + charges.fixedTotal;
        return ldp.setScale(COST_SCALE, RoundingMode.HALF_UP);
    }

    /**
     * The upcharge row whose range contains the quantity. When ranges overlap, the row
     * with the highest lower bound wins (rows arrive sorted by lower bound descending).
     */
    @TestVisible
    private static Manufacturer_Upcharge__c findUpcharge(List<Manufacturer_Upcharge__c> upcharges, Integer quantity) {
        if (upcharges == null) {
            return null;
        }
        for (Manufacturer_Upcharge__c upcharge : upcharges) {
            if (upcharge.Quantity_Lower_Bound__c == null || upcharge.Quantity_Lower_Bound__c > quantity) {
                continue;
            }
            if (upcharge.Quantity_Upper_Bound__c == null || upcharge.Quantity_Upper_Bound__c >= quantity) {
                return upcharge;
            }
        }
        return null;
    }

    @TestVisible
    private static Charges toCharges(mfg__c manufacturer) {
        Charges charges = new Charges();
        // Percent fields hold whole numbers (3 for 3%).
        charges.percentTotal = (nz(manufacturer.Duty_Rate__c) + nz(manufacturer.MPF_Rate__c)
            + nz(manufacturer.Insurance_Rate__c) + nz(manufacturer.Finance_Rate__c)) / 100;
        charges.fixedTotal = nz(manufacturer.Broker_Fee__c) + nz(manufacturer.Freight__c)
            + nz(manufacturer.WH_HDL__c) + nz(manufacturer.Marketing_Fee__c)
            + nz(manufacturer.Compliance_Fee__c);
        return charges;
    }

    private static Boolean hasAnyCharge(mfg__c manufacturer) {
        return manufacturer.Duty_Rate__c != null || manufacturer.MPF_Rate__c != null
            || manufacturer.Insurance_Rate__c != null || manufacturer.Finance_Rate__c != null
            || manufacturer.Broker_Fee__c != null || manufacturer.Freight__c != null
            || manufacturer.WH_HDL__c != null || manufacturer.Marketing_Fee__c != null
            || manufacturer.Compliance_Fee__c != null;
    }

    private static List<Integer> cleanQuantities(List<Integer> quantities) {
        List<Integer> result = new List<Integer>();
        Set<Integer> seen = new Set<Integer>();
        for (Integer quantity : quantities == null ? new List<Integer>() : quantities) {
            if (quantity == null || quantity <= 0 || seen.contains(quantity)) {
                continue;
            }
            seen.add(quantity);
            result.add(quantity);
            if (result.size() == MAX_QUANTITIES) {
                break;
            }
        }
        result.sort();
        return result;
    }

    private static CostLine line(String label, Decimal cost) {
        CostLine costLine = new CostLine();
        costLine.label = label;
        costLine.cost = cost;
        return costLine;
    }

    private static String displayName(Product2 product) {
        return String.isNotBlank(product.ProductCode) ? product.ProductCode : product.Name;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }
}
