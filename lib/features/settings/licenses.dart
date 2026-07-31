// Centralized license registry for Nomad.
//
// Each entry has:
//   - id   : URL-safe identifier (used by GoRouter path)
//   - name : Display name of the licensed component
//   - type : Short license type label (e.g. "MIT", "Apache 2.0")
//   - text : Full license text

class LicenseEntry {
  final String id;
  final String name;
  final String type;
  final String text;

  const LicenseEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.text,
  });
}

class NomadLicenses {
  static const List<LicenseEntry> all = [
    LicenseEntry(
      id: 'nomad',
      name: 'Nomad',
      type: 'MIT',
      text: _mitText,
    ),
    LicenseEntry(
      id: 'qwen',
      name: 'Qwen 3.5',
      type: 'Apache 2.0',
      text: _apacheText,
    ),
    LicenseEntry(
      id: 'gemma',
      name: 'Gemma 4',
      type: 'Gemma Terms of Use',
      text: _gemmaText,
    ),
  ];

  static LicenseEntry? byId(String id) {
    for (final e in all) {
      if (e.id == id) return e;
    }
    return null;
  }
}

const _mitText = '''
MIT License

Copyright (c) 2024 Finn Technologies

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';

const _apacheText = '''
Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

"License" shall mean the terms and conditions for use, reproduction,
and distribution as defined by Sections 1 through 9 of this document.

"Licensor" shall mean the copyright owner or entity authorized by
the copyright owner that is granting the License.

"Legal Entity" shall mean the union of the acting entity and all
other entities that control, are controlled by, or are under common
control with that entity.

"You" (or "Your") shall mean an individual or Legal Entity
exercising permissions granted by this License.

"Source" form shall mean the preferred form for making modifications,
including but not limited to software source code, documentation
source, and configuration files.

"Object" form shall mean any form resulting from mechanical
transformation or translation of a Source form.

"Work" shall mean the work of authorship, whether in Source or
Object form, made available under the License.

"Derivative Works" shall mean any work, whether in Source or Object
form, that is based on (or derived from) the Work.

"Contribution" shall mean any work of authorship that is intentionally
submitted to Licensor for inclusion in the Work.

"Contributor" shall mean Licensor and any individual or Legal Entity
on behalf of whom a Contribution has been received by Licensor.

2. Grant of Copyright License. Subject to the terms and conditions of
this License, each Contributor hereby grants to You a perpetual,
worldwide, non-exclusive, no-charge, royalty-free, irrevocable
copyright license to reproduce, prepare Derivative Works of,
publicly display, publicly perform, sublicense, and distribute the
Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of
this License, each Contributor hereby grants to You a perpetual,
worldwide, non-exclusive, no-charge, royalty-free, irrevocable
(except as stated in this section) patent license to make, have made,
use, offer to sell, sell, import, and otherwise transfer the Work.

4. Redistribution. You may reproduce and distribute copies of the
Work or Derivative Works thereof in any medium, with or without
modifications, in Source or Object form, provided that You meet the
following conditions:

(a) You must give any other recipients of the Work or
Derivative Works a copy of this License; and

(b) You must cause any modified files to carry prominent notices
stating that You changed the files; and

(c) You must retain, in the Source form of any Derivative Works
that You distribute, all copyright, patent, trademark, and
attribution notices from the Source form of the Work; and

(d) If the Work includes a "NOTICE" text file as part of its
distribution, then any Derivative Works that You distribute must
include a copy of the attribution notices contained within
such NOTICE file.

5. Submission of Contributions. Unless You explicitly state otherwise,
any Contribution intentionally submitted for inclusion in the Work
by You to the Licensor shall be under the terms and conditions of
this License.

6. Trademarks. This License does not grant permission to use the trade
names, trademarks, service marks, or product names of the Licensor.

7. Disclaimer of Warranty. Unless required by applicable law or
agreed to in writing, Licensor provides the Work (and each
Contributor provides its Contributions) on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied.

8. Limitation of Liability. In no event and under no legal theory,
whether in tort (including negligence), contract, or otherwise,
unless required by applicable law or agreed to in writing, shall
any Contributor be liable to You for damages.

9. Accepting Warranty or Additional Liability. While redistributing
the Work or Derivative Works thereof, You may choose to offer,
and charge a fee for, acceptance of support, warranty, indemnity,
or other liability obligations and/or rights consistent with this
License.

END OF TERMS AND CONDITIONS
''';

const _gemmaText = '''
Gemma Terms of Use

Last modified: April 1, 2024

By using, reproducing, modifying, distributing, performing or displaying any
portion or element of Gemma, Model Derivatives including via any Hosted
Service, (each as defined below) (collectively, the "Gemma Services") or
otherwise accepting the terms of this Agreement, you agree to be bound by
this Agreement.

Section 1: Definitions

1.1 "Agreement" or "Gemma Terms of Use" means these terms and conditions
that govern the use, reproduction, Distribution or modification of the Gemma
Services and any terms and conditions incorporated by reference.

1.2 "Distribution" or "Distribute" means any transmission, publication, or
other sharing of Gemma or Model Derivatives to a third party, including by
providing or making Gemma or its functionality available as a hosted service
via API, web access, or any other electronic or remote means ("Hosted
Service").

1.3 "Gemma" means the set of machine learning language models, trained model
weights and parameters identified at ai.google.dev/gemma, regardless of the
source that you obtained it from.

1.4 "Google" means Google LLC.

1.5 "Model Derivatives" means all (i) modifications to Gemma, (ii) works
based on Gemma, or (iii) any other machine learning model which is created
by transfer of patterns of the weights, parameters, operations, or Output of
Gemma, to that model in order to cause that model to perform similarly to
Gemma, including distillation methods that use intermediate data
representations or methods based on the generation of synthetic data Outputs
by Gemma for training that model. For clarity, Outputs by themselves are not
deemed Model Derivatives.

1.6 "Output" means the information content output of Gemma or a Model
Derivative that results from operating or otherwise using Gemma or the Model
Derivative, including via a Hosted Service.

Section 2: License Rights and Redistribution

2.1 License. Subject to your compliance with this Agreement, Google grants
you a non-exclusive, worldwide, non-transferable, royalty-free, revocable
license to use, reproduce, Distribute, create Model Derivatives of, and make
modifications to, Gemma.

2.2 Restrictions. You may not, and will not permit, assist or cause any
third party to use, Distribute, copy, modify, or create Model Derivatives
of, Gemma or Model Derivatives:

(a) for any Prohibited Use as set forth in the Gemma Prohibited Use
Policy available at ai.google.dev/gemma/prohibited_use_policy
("Prohibited Use Policy");

(b) in violation of applicable laws and regulations (including trade
compliance laws and regulations) or in violation of third party
rights, including, but not limited to, intellectual property,
privacy, and/or other proprietary rights; or

(c) to generate content used to defame, harass, abuse, threaten, or
mislead any person.

2.3 Attribution. You must retain in all copies of Gemma or Model Derivatives
that you Distribute the following attribution notice within a "Notice" text
file distributed as a part of such copies: "Gemma is provided under and
subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms".

2.4 Updates. Google may update Gemma from time to time. You must make
reasonable efforts to use the latest version of Gemma.

Section 3: Disclaimer of Warranty

UNLESS REQUIRED BY APPLICABLE LAW, GEMMA AND ANY OUTPUTS AND RESULTS
THEREFROM ARE PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
AND GOOGLE DISCLAIMS ALL WARRANTIES OF ANY KIND, BOTH EXPRESS AND IMPLIED,
INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OF TITLE, MERCHANTABILITY,
NONINFRINGEMENT OR FITNESS FOR A PARTICULAR PURPOSE. YOU ARE SOLELY
RESPONSIBLE FOR DETERMINING THE APPROPRIATENESS OF USING OR REDISTRIBUTING
GEMMA AND ASSUME ANY RISKS ASSOCIATED WITH YOUR USE OF GEMMA AND ANY OUTPUTS
AND RESULTS.

Section 4: Limitation of Liability

TO THE FULLEST EXTENT PERMITTED BY APPLICABLE LAW, IN NO EVENT AND UNDER NO
LEGAL THEORY, WHETHER IN TORT (INCLUDING NEGLIGENCE), PRODUCT LIABILITY, OR
OTHERWISE SHALL GOOGLE OR ITS AFFILIATES BE LIABLE FOR ANY DIRECT, INDIRECT,
SPECIAL, INCIDENTAL, EXEMPLARY, CONSEQUENTIAL, OR PUNITIVE DAMAGES, OR LOST
PROFITS OF ANY KIND ARISING FROM THIS AGREEMENT OR RELATED TO THE GEMMA
SERVICES, EVEN IF GOOGLE OR ITS AFFILIATES HAVE BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGES.

Section 5: Term, Termination, and Survival

5.1 Term. The term of this Agreement will commence upon your acceptance of
this Agreement and will continue in full force and effect until terminated
in accordance with the terms of this Agreement.

5.2 Termination. Google may terminate this Agreement if you are in breach of
any term of this Agreement. Upon termination of this Agreement, you must
delete and cease use and Distribution of all copies of Gemma and Model
Derivatives in your possession or control. Sections 1, 2.2, 3, 4, 5.2, 5.3,
6, 7, 8 and 9 shall survive the termination of this Agreement.

Section 6: Governing Law and Jurisdiction

This Agreement will be governed by the laws of the State of California
without regard to choice of law principles. The UN Convention on Contracts
for the International Sale of Goods does not apply to this Agreement. The
state and federal courts of Santa Clara County, California shall have
exclusive jurisdiction of any dispute arising out of this Agreement.

Section 7: Modifications and Updates

Google may modify this Agreement from time to time by posting a revised
version. By continuing to use or access the Gemma Services after the
revisions come into effect, you agree to be bound by the revised Agreement.

For the most recent version of these terms, please visit:
ai.google.dev/gemma/terms
''';
