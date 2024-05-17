/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

import groovy.io.FileType
import nextflow.Nextflow

include { paramsSummaryMap       } from 'plugin/nf-validation'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_mcmicro_pipeline'
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { BASICPY                } from '../modules/nf-core/basicpy/main'
include { ASHLAR                 } from '../modules/nf-core/ashlar/main'
include { BACKSUB                } from '../modules/nf-core/backsub/main'
include { CELLPOSE               } from '../modules/nf-core/cellpose/main'
include { DEEPCELL_MESMER        } from '../modules/nf-core/deepcell/mesmer/main'
include { MCQUANT                } from '../modules/nf-core/mcquant/main'
include { SCIMAP_MCMICRO         } from '../modules/nf-core/scimap/mcmicro/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow MCMICRO {

    take:
    ch_samplesheet // channel: samplesheet read in from --input_cycle or --input_sample
    ch_markersheet // channel: markersheet read in from --marker_sheet

    main:

    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()

    //
    // MODULE: BASICPY
    //
    if (params.illumination == 'basicpy') {
        ch_basicpy_in = ch_samplesheet
            .map{ meta, image_tiles, dfp, ffp ->
                [meta.subMap('id', 'cycle_number'), image_tiles]
            }
            .dump(tag: 'ch_basicpy_in')
        BASICPY(ch_basicpy_in)
        ch_samplesheet = ch_samplesheet
            .map{ meta, image_tiles, dfp, ffp ->
                [meta.subMap('id', 'cycle_number'), image_tiles]
            }
            .join(BASICPY.out.profiles)
            .dump(tag: 'ch_samplesheet (after BASICPY)')
    }

    ch_ashlar_in = ch_samplesheet
        .map{ meta, image_tiles, dfp, ffp ->
            [[id: meta.id], [meta.cycle_number, image_tiles, dfp, ffp]]
        }
         // FIXME: pass groupTuple size: from samplesheet cycle count
        .groupTuple(sort: { a, b -> a[0] <=> b[0] })
        .map{ meta, cycles -> [meta, *cycles.collect{ it[1..-1] }.transpose()]}
        // flatten() handles list of empty-lists, turning it into a single empty list.
        .map{ meta, images, dfps, ffps -> [meta, images, dfps.flatten(), ffps.flatten()] }
        .dump(tag: 'ch_ashlar_in')
    ASHLAR(ch_ashlar_in)
    ch_versions = ch_versions.mix(ASHLAR.out.versions)

    // // Run Background Correction
    // BACKSUB(ASHLAR.out.tif, ch_markers)
    //BACKSUB(ASHLAR.out.tif, [[id: "backsub"], params.marker_sheet])
    //ch_versions = ch_versions.mix(BACKSUB.out.versions)

    // Run Segmentation

    DEEPCELL_MESMER(ASHLAR.out.tif, [[:],[]])
    ch_versions = ch_versions.mix(DEEPCELL_MESMER.out.versions)

    // Run Quantification
    mcquant_in = ASHLAR.out.tif.join(DEEPCELL_MESMER.out.mask).multiMap { it ->
        image: [it[0], it[1]]
        mask: [it[0], it[2]]
    }
    MCQUANT(mcquant_in.image,
            mcquant_in.mask,
            [[:], file(params.marker_sheet)])
    ch_versions = ch_versions.mix(MCQUANT.out.versions)

    /*
    // // Run Reporting
    SCIMAP_MCMICRO(MCQUANT.out.csv)
    ch_versions = ch_versions.mix(SCIMAP_MCMICRO.out.versions)
    */

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(storeDir: "${params.outdir}/pipeline_info", name: 'nf_core_pipeline_software_mqc_versions.yml', sort: true, newLine: true)
        .set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config                     = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config              = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
    ch_multiqc_logo                       = params.multiqc_logo ? Channel.fromPath(params.multiqc_logo, checkIfExists: true) : Channel.empty()
    summary_params                        = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary                   = Channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(methodsDescriptionText(ch_multiqc_custom_methods_description))
    ch_multiqc_files                      = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files                      = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files                      = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: false))

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
