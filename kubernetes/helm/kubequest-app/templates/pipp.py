"""
tables.compare_mission
=========================
Contrôle de cohérence de la table 'mission' : hub (CW1) vs SMART.

Particularité de cette table : 4 clés étrangères côté hub (statut, type
de mission, service, auditeur) qui doivent être résolues en libellés
avant comparaison, car SMART ne donne que le libellé.
"""

from datetime import datetime

from comparator import (
    load_table_pair,
    compare_volumetrie,
    compare_par_cle,
    detect_divergences_valeurs,
    summary_report,
    export_report,
)

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

NOM_TABLE = "mission"

KEY_HUB = "id_mission"
KEY_SMART = "id"

VALUE_PAIRS = [
    ("libelle", "Libelle"),
    ("date_debut", "DateDebut"),
    ("date_fin", "DateFin"),
    ("statut_libelle", "Statut"),              # résolu à l'étape 1bis
    ("type_mission_libelle", "TypeMission"),    # résolu à l'étape 1bis
    ("service_libelle", "Service"),              # résolu à l'étape 1bis
    ("auditeur_libelle", "Auditeur"),             # résolu à l'étape 1bis
    ("budget", "Budget"),
    ("commentaire", "Commentaire"),
]


# ---------------------------------------------------------------------------
# EXECUTION
# ---------------------------------------------------------------------------

def main():
    # 1. Chargement
    df_hub, df_smart = load_table_pair(NOM_TABLE)

    # 1bis. RESOLUTION DES 4 CLES ETRANGERES (hub uniquement)
    # Chaque table de référence est chargée via load_table_pair, dont on ne
    # garde que [0] (le côté hub) -- ces tables de référence n'existent pas
    # forcément côté SMART, et on n'en a pas besoin ici.

    df_statut = load_table_pair("statut")[0]
    df_hub = df_hub.merge(
        df_statut[["statut_id", "statut_libelle"]],
        on="statut_id",
        how="left",
    )

    df_type_mission = load_table_pair("type_mission")[0]
    df_hub = df_hub.merge(
        df_type_mission[["type_mission_id", "type_mission_libelle"]],
        on="type_mission_id",
        how="left",
    )

    df_service = load_table_pair("service")[0]
    df_hub = df_hub.merge(
        df_service[["service_id", "service_libelle"]],
        on="service_id",
        how="left",
    )

    df_auditeur = load_table_pair("auditeur")[0]
    df_hub = df_hub.merge(
        df_auditeur[["auditeur_id", "auditeur_libelle"]],
        on="auditeur_id",
        how="left",
    )

    # 2. Comparaison
    volumetrie = compare_volumetrie(df_hub, df_smart)
    comparison = compare_par_cle(df_hub, df_smart, key_hub=KEY_HUB, key_smart=KEY_SMART)
    divergences = detect_divergences_valeurs(comparison, VALUE_PAIRS)
    summary = summary_report(volumetrie, comparison, divergences)

    print(f"\n=== Résumé — {NOM_TABLE} ===")
    print(summary.to_string(index=False))

    # 3. Export
    output_path = f"outputs/rapport_{NOM_TABLE}_{datetime.now():%Y%m%d_%H%M}.xlsx"
    export_report(summary, comparison, divergences, output_path)


if __name__ == "__main__":
    main()