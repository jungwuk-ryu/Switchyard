# GPTK 3 Redistribution Review

## Decision

**Review date:** 2026-07-22<br>
**Decision:** Conditional GO for implementation; public distribution requires independent legal sign-off<br>
**Approved scope:** A separate, free-of-charge Switchyard download channel containing only the exact, unmodified Game Porting Toolkit 3 Framework and/or components from its `/redist` directory

Switchyard may implement a curated GPTK 3 component download if every control in this document is enforced before the channel is enabled. This decision does not approve putting GPTK in this repository, the app bundle, a Wine runtime, or a combined release archive. It does not approve Game Porting Toolkit 4 or any other package whose accompanying license has not been reviewed.

This is the project's documented legal-risk and engineering review, not an attorney-client legal opinion. It is sufficient to proceed with the narrowly scoped, release-disabled implementation described here. Public distribution requires either written Apple confirmation of the Section 3 interpretation below or written approval from independent counsel qualified to advise the distributor. The same independent approval is required before relaxing any condition or using the channel as part of a commercial offering.

## Material Reviewed

The following Apple-provided GPTK 3 artifact was inspected locally. No Apple binary or license file is stored in this repository.

| Item | Reviewed identity |
| --- | --- |
| Outer image | `Game_Porting_Toolkit_3.0.dmg`; SHA-256 `ac8f6eeb2b9e5244d4c8eeb5b69b5cec099b560b143a7e5ef413945fc48b0f8f` |
| Evaluation image | `Evaluation environment for Windows games 3.0.dmg`; SHA-256 `d49395fb07e536804d1da0858590e53f6aa6fab12512e18fd80a74c87f9f063c` |
| Accompanying license | `License.rtf`; SHA-256 `5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8`; Apple document `EA18380`, dated 2023-08-17 |
| Accompanying acknowledgements | `Acknowledgements.rtf`; SHA-256 `6f3aa835f6d0d06f89997d0a346a209e39a8105521fd939e096c5b24dc0cb0a6` |
| Framework third-party notice | `D3DMetal.framework/Versions/A/Resources/LICENSE`; SHA-256 `553d0035773ddd1590045f8fdc3a4c6ead31e36336721aeca8421e88ed1c9f80` |
| Framework signature | Bundle identifier `com.apple.D3DMetal`; Apple Software Signing certificate chain; full SHA-256 CDHash `bc0127bf883aff9aa2e483d3cebdfec6470fab3f15918e3b9aabf61cc14e53c9` |

The review also considered Apple's current [Game Porting Toolkit page](https://developer.apple.com/games/game-porting-toolkit/), [developer agreements index](https://developer.apple.com/support/terms/), [Apple Developer Agreement](https://developer.apple.com/support/downloads/terms/apple-developer-agreement/Apple-Developer-Agreement-20250318-English.pdf), and [trademark guidelines](https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html). Apple states that the English agreements accepted in a developer account are the binding and most current versions. The license accompanying each downloaded GPTK package therefore controls the review for that package.

## License Findings

The reviewed GPTK 3 license defines the Apple Software to include the Framework (`D3DMetal.framework`) and the Redistributables (components within `/redist`). Its operative grants and limits are:

- Section 2A(iii) expressly permits distribution of the Apple Software solely for non-commercial purposes and in accordance with the agreement.
- Section 2C expressly permits the complete Framework or any part of the Redistributables to be distributed separately. Every such distribution remains subject to the non-commercial restriction.
- Section 3 separately says that any copy Apple may provide for promotional, evaluation, diagnostic, or restorative purposes may be used only for that purpose and may not be resold or transferred.
- Copyright and proprietary notices must be preserved on copies.
- Installation, internal use, and testing are limited to developing, testing, or evaluating video games for Apple-branded products. The software is supported only on qualifying Apple-branded hardware and software.
- The Apple Software may not be sold, rented, leased, lent, hosted, modified, reverse engineered, or used to provide service-bureau, time-sharing, terminal-sharing, or similar services.
- Use with third-party material is allowed only when the user owns it or is otherwise authorized or legally permitted to use it.
- Section 13 points to the accompanying acknowledgements for additional open-source and third-party terms. Those notices impose their own binary-redistribution attribution requirements.
- Distribution and use remain subject to U.S. export controls and applicable local law. Apple may terminate the license, after which the licensee must stop use and destroy every full or partial copy in its possession or control.

The general Apple Developer Agreement prohibits redistribution unless a separate Apple agreement permits it. The reviewed GPTK 3 license supplies that specific permission. Conversely, the general agreement treats pre-release Apple material as confidential and non-transferable unless accompanying terms provide otherwise. No current GPTK 4 accompanying license was available for this review, so the GPTK 3 result cannot be extended to GPTK 4 by inference.

## Interpretation for Switchyard

A Switchyard-hosted download is itself a distribution by the project even when the app merely retrieves it. It can fit the reviewed grant only when the distribution is genuinely non-commercial and the payload stays within Section 2C.

Sections 2A and 2C specifically authorize non-commercial reproduction and distribution of the Framework and Redistributables, while Section 3 prohibits resale or transfer of an Apple-provided evaluation copy. The project's narrow working interpretation is that it may create and distribute component copies under Sections 2A and 2C but may not transfer the Apple-provided outer or evaluation DMG, an Apple account, or the licensee's rights. This gives effect to both provisions instead of making the express component-distribution grant meaningless. Because the reviewed image is itself named “Evaluation environment for Windows games,” material ambiguity remains. This review does not finally resolve that ambiguity; written Apple confirmation or independent qualified counsel approval is a mandatory public-release gate.

For this project, “non-commercial distribution” is implemented conservatively as all of the following:

- The GPTK artifact and access to it are free of charge.
- Access is not conditioned on a purchase, subscription, paid support plan, sponsorship, donation, account upgrade, advertising interaction, or other consideration.
- The artifact is not used to market, unlock, or add value to a paid Switchyard edition or service.
- No fee is charged for bandwidth, packaging, installation, support entitlement, or redistribution.
- Switchyard does not sell, sublicense, rent, host as a service, or provide remote access to the Apple Software.

Open-source publication does not by itself prove a non-commercial purpose. Any monetization, acquisition by a commercial distributor, paid product tier, advertising, or consideration tied to the channel automatically suspends distribution pending a new review or written Apple permission. Unconditioned donations to the overall open-source project must not affect access, placement, or support for the GPTK channel.

The reviewed license does not expressly require every recipient of a Section 2C component copy to obtain it through an Apple Developer account. That observation does not transfer the original licensee's rights or broaden the recipient's permitted use. The user-facing flow must present the unmodified accompanying license before download and make clear that the environment is for development, testing, or evaluation on Apple-branded products—not an unrestricted consumer gaming runtime.

## Mandatory Release Controls

The channel must remain disabled until all controls below are implemented and verified.

### Distributor authority

- Identify the legal person or entity operating the download channel. That distributor must be the licensee that accepted the reviewed Apple terms and obtained the reviewed image through Apple's official path, or must hold documented authority to act for that licensee.
- Keep a private release record of the licensee's legal identity, exact terms accepted, acceptance timestamp, official acquisition source and timestamp, acquisition evidence, authority for the release operator, and the account or organization that controls the distribution host. Do not publish Apple account credentials or unnecessary personal data.
- A change of licensee, release operator authority, repository owner, CDN account owner, or distribution legal entity automatically disables the channel and requires a new review.

### Payload and provenance

- Build component copies from the exact Apple-provided image identified above. A Heroic, Gcenx, or other third-party archive may be used for comparison only, never as the authoritative input.
- Do not publish or transfer the Apple-provided outer DMG or evaluation DMG. Include only a newly packaged copy of the complete, unmodified `D3DMetal.framework` and/or an unmodified subset of `/redist` within the specific Section 2C grant. Do not add GPTK files to the Wine archive, Switchyard archive, app bundle, source repository, or container template.
- Preserve paths, file contents, extended metadata required for operation, code signatures, copyright notices, the exact accompanying license, and applicable acknowledgements. Compression may change only the outer transport representation of the expressly permitted component copies.
- Generate a payload-specific third-party license inventory. Verify and ship every applicable notice, including the reviewed `Acknowledgements.rtf` terms and the Framework's embedded `Resources/LICENSE`; fail the release if an included file's notice obligation is unknown or unsatisfied.
- Publish an immutable, signed manifest containing the source image identities, permitted path list, archive size and SHA-256, extracted file-tree digest, Apple code-signing requirements, license identity, and review date. Do not use a mutable `latest` URL as authority.
- At install time, reject digest mismatches, unlisted or escaping paths, missing notices, modified Mach-O files, and signatures that do not satisfy the pinned Apple requirements.

### User flow and positioning

- Show the exact accompanying Apple license before the download begins. Record the user's acknowledgement locally; do not claim that Switchyard accepts Apple's agreement on the user's behalf.
- State that Apple Software remains Apple-licensed software, is not covered by Switchyard's MIT license, and is provided without Switchyard or Apple warranty.
- Require acknowledgement that the software will run only on supported Apple-branded hardware, for developing, testing, or evaluating video games, and only with material the user owns or is authorized to use.
- Do not describe the channel as a general-purpose consumer game runtime. Do not imply Apple endorsement, sponsorship, partnership, or approval. Use Apple word marks only referentially and do not use the Apple logo.
- Keep the current official Apple-download/import route available as a fallback.

### Operations

- Use a distribution host and release process that actually enforces applicable geographic and restricted-party controls, or contractually accepts responsibility for doing so. An unrestricted anonymous public mirror is not an approved host.
- Provide an immediate remote disable/takedown mechanism for the catalog entry. On termination or an Apple takedown request, disable access and purge the host origin, controlled mirrors, CDN caches, build workspaces, and every other full or partial copy in the distributor's possession or control. User-managed copies outside the distributor's control are not silently deleted by Switchyard; any additional notice or deletion obligation must be handled under the applicable termination instructions.
- Reconfirm the project's non-commercial status and the immutable artifact manifest for every release that enables the channel.
- Obtain written Apple confirmation of the Section 3 interpretation or written approval from independent counsel qualified to advise the identified distributor. Store the approval with the private release record.
- Treat any license change, new GPTK version, App Store distribution, commercial feature, paid relationship, Apple objection, or material change in hosting as a mandatory re-review trigger.

## Decision Matrix

| Scenario | Decision |
| --- | --- |
| Existing user-selected Apple GPTK import | GO; current supported path |
| Exact reviewed GPTK 3 Framework or `/redist` subset through a separate free channel | Conditional GO after every mandatory control and independent legal sign-off passes |
| Apple-provided outer or evaluation DMG transferred to recipients | NO-GO under the Section 3 risk boundary |
| Third-party repack as the authoritative supply-chain source | NO-GO |
| GPTK in this repository, app bundle, Wine runtime, or combined release | NO-GO |
| Paid, ad-supported, purchase-linked, or service-hosted GPTK distribution | NO-GO without written Apple permission or a new counsel review |
| General consumer-play positioning that omits the licensed evaluation purpose | NO-GO |
| GPTK 4 or any unreviewed version | NO-GO until its exact accompanying license and artifact are reviewed |

## Implementation Authorization

Engineering may now implement the exact GPTK 3 component channel behind a release-disabled gate. This review alone does not authorize public distribution. Enabling the public channel requires tests or release evidence for every mandatory control, a version-specific maintainer attestation, and the independent legal sign-off described above. No further legal assumption may be made from Heroic's or another project's behavior.
