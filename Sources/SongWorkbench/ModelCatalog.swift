import Foundation

enum ModelCatalog {
    static let htdemucs = ModelPackageDescriptor(
        id: "htdemucs-6s-onnx",
        displayName: "HTDemucs 6-Source ONNX",
        purpose: "Six-stem separation: vocals, drums, bass, guitar, piano, and other",
        version: "125b3e0",
        minimumOSVersion: "14.0",
        license: ModelArtifactLicense(
            name: "CC-BY-NC-4.0",
            attribution: "HTDemucs by Meta; full-graph ONNX export by MansfieldPlumbing"
        ),
        source: .files([
            ModelPackageComponent(
                relativePath: "demucsv4.onnx",
                downloadURL: URL(
                    string:
                        "https://huggingface.co/MansfieldPlumbing/Demucs_v4_TRT/resolve/main/demucsv4.onnx?download=true"
                )!,
                expectedSizeBytes: 246_148_867,
                sha256: "4bef152b260bb7ac65daabd591a673195f6c9b0e9eeb330bce6e834530388b0d"
            )
        ]),
        entryPointRelativePath: "demucsv4.onnx"
    )

    static let whisperAccuracy = ModelPackageDescriptor(
        id: "whisper-large-v3-turbo-q5-0",
        displayName: "Whisper Large V3 Turbo Q5_0",
        purpose: "Accuracy lyric transcription",
        version: "1",
        minimumOSVersion: "14.0",
        license: ModelArtifactLicense(
            name: "MIT",
            attribution: "Whisper by OpenAI; GGML conversion by ggml-org"
        ),
        source: .files([
            ModelPackageComponent(
                relativePath: "ggml-large-v3-turbo-q5_0.bin",
                downloadURL: URL(
                    string:
                        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
                )!,
                expectedSizeBytes: 574_041_195,
                sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
            )
        ]),
        entryPointRelativePath: "ggml-large-v3-turbo-q5_0.bin"
    )

    static let parakeetFastDraft = ModelPackageDescriptor(
        id: "parakeet-tdt-0.6b-v3-coreml-int8",
        displayName: "Parakeet TDT 0.6B V3 Core ML",
        purpose: "Fast-draft lyric transcription",
        version: "main-2026-06-21",
        minimumOSVersion: "14.0",
        license: ModelArtifactLicense(
            name: "CC-BY-4.0",
            attribution: "Parakeet by NVIDIA; Core ML conversion by FluidInference"
        ),
        source: .files(parakeetComponents),
        entryPointRelativePath: "parakeet-tdt-0.6b-v3-coreml"
    )

    static let all = [htdemucs, parakeetFastDraft, whisperAccuracy]

    private static let parakeetBaseURL =
        "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/"

    private static let parakeetComponents: [ModelPackageComponent] = [
        parakeet(
            "Preprocessor.mlmodelc/analytics/coremldata.bin", 243,
            "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        parakeet(
            "Preprocessor.mlmodelc/coremldata.bin", 486,
            "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        parakeet(
            "Preprocessor.mlmodelc/metadata.json", 2_841,
            "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        parakeet(
            "Preprocessor.mlmodelc/model.mil", 28_181,
            "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        parakeet(
            "Preprocessor.mlmodelc/weights/weight.bin", 491_072,
            "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        parakeet(
            "Encoder.mlmodelc/analytics/coremldata.bin", 243,
            "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        parakeet(
            "Encoder.mlmodelc/coremldata.bin", 485,
            "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        parakeet(
            "Encoder.mlmodelc/metadata.json", 2_921,
            "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        parakeet(
            "Encoder.mlmodelc/model.mil", 959_769,
            "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        parakeet(
            "Encoder.mlmodelc/weights/weight.bin", 445_187_200,
            "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        parakeet(
            "Decoder.mlmodelc/analytics/coremldata.bin", 243,
            "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        parakeet(
            "Decoder.mlmodelc/coremldata.bin", 554,
            "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        parakeet(
            "Decoder.mlmodelc/metadata.json", 3_427,
            "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        parakeet(
            "Decoder.mlmodelc/model.mil", 13_110,
            "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        parakeet(
            "Decoder.mlmodelc/weights/weight.bin", 23_604_992,
            "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        parakeet(
            "JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243,
            "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        parakeet(
            "JointDecisionv3.mlmodelc/coremldata.bin", 521,
            "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        parakeet(
            "JointDecisionv3.mlmodelc/metadata.json", 3_453,
            "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        parakeet(
            "JointDecisionv3.mlmodelc/model.mil", 11_775,
            "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        parakeet(
            "JointDecisionv3.mlmodelc/weights/weight.bin", 12_642_764,
            "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        parakeet(
            "parakeet_vocab.json", 151_122,
            "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    private static func parakeet(
        _ path: String,
        _ size: Int64,
        _ sha256: String
    ) -> ModelPackageComponent {
        ModelPackageComponent(
            relativePath: "parakeet-tdt-0.6b-v3-coreml/" + path,
            downloadURL: URL(string: parakeetBaseURL + path)!,
            expectedSizeBytes: size,
            sha256: sha256
        )
    }
}
