# R0/maintainability: this suite is dot-sourced by test-compliance.ps1.
# Required runner context: profile-derived source paths and the three
# Assert-*Literal helpers. These checks intentionally inspect trusted profile
# implementation text; semantic Pandoc fixtures belong to another suite.

# Static regression tests execute against the trusted implementation sources.
# They verify structure and exact centralised commands, not marker presence.

# STO-7.1.3, STO-A1: Appendix A1 title form fields and their order.
Assert-OrderedLiterals 'STO-A1' $templateSourcePath @(
    '$parent-organization$', '$university$', '$faculty-label$', '$school$',
    '$department$', '$title$', '$discipline$', '$document-code$',
    '$normal-controller.name$', '$supervisor.name$', '$student.group$',
    '$student.name$', '$city$', '$year$'
)

# STO-V: selected two-page coursework assignment form and signatures.
Assert-OrderedLiterals 'STO-V' $templateSourcePath @(
    '$if(include-assignment)$', '$assignment.head-of-department$',
    '$assignment.approval-date$', '$assignment.student-full-name$',
    '$discipline$', '$title$', '$assignment.due-date$',
    '$for(assignment.questions)$', '\clearpage', '$for(assignment.calendar)$',
    '$supervisor.name$', '$student.name$', '$if(abstract)$'
)

# STO-7.3.1: assignment, annotation and contents have a fixed order.
Assert-OrderedLiterals 'STO-7.3.1' $templateSourcePath @(
    '$if(include-assignment)$', '$if(abstract)$', '$abstract$', '\tableofcontents'
)

# STO-7.11.2, STO-7.11.4: one biblatex end-list backend, citation order,
# no hidden nocite-all path that could print an unreferenced source.
Assert-ContainsLiteral 'STO-7.11.2' $rendererSourcePath @('\printbibliography')
Assert-ContainsLiteral 'STO-7.11.4' $templateSourcePath @(
    'backend=biber', 'style=gost-numeric', 'sorting=none'
)
Assert-ContainsLiteral 'STO-7.11.4' 'scripts/build.ps1' @('--biblatex')
Assert-NotContainsLiteral 'STO-7.11.4' $templateSourcePath @('\nocite{*}')

# STO-7.12.7, STO-7.12.8: page counter stays global while the structural
# hierarchy and object counters become appendix-local.
Assert-ContainsLiteral 'STO-7.12.8' $styleSourcePath @(
    '\renewcommand{\thesection}{#1.\arabic{section}}',
    '\renewcommand{\thesubsection}{\thesection.\arabic{subsection}}'
)
Assert-NotContainsLiteral 'STO-7.12.7' $styleSourcePath @(
    '\setcounter{page}{0}', '\setcounter{page}{1}'
)

# STO-8.2.3, STO-8.2.6, STO-8.2.7, STO-8.2.9, STO-8.2.11: automatic
# hierarchy, heading layout, keep-with-next space and permitted list marker.
Assert-ContainsLiteral 'STO-8.2.3' $styleSourcePath @(
    '\setcounter{secnumdepth}{4}', '\setcounter{tocdepth}{4}'
)
Assert-ContainsLiteral 'STO-8.2.6' $styleSourcePath @(
    '\titleformat{\section}[block]', '{\thesection}{0.6em}{\MakeUppercase}'
)
Assert-ContainsLiteral 'STO-8.2.7' $styleSourcePath @(
    '\titlespacing*{\subsection}{\parindent}',
    '\titlespacing*{\subsubsection}{\parindent}'
)
Assert-ContainsLiteral 'STO-8.2.9' $styleSourcePath @(
    '\pretocmd{\section}{\Needspace{10\baselineskip}}',
    '\pretocmd{\subsection}{\Needspace{8\baselineskip}}'
)
Assert-ContainsLiteral 'STO-8.2.11' $styleSourcePath @(
    '\setlist{nosep,leftmargin=\parindent',
    '\setlist[enumerate,1]{label=\arabic*)}'
)

# STO-8.4.3, STO-8.4.5: central decimal/group/unit policy and nonbreaking
# object references in the trusted renderer.
Assert-ContainsLiteral 'STO-8.4.3' $styleSourcePath @(
    'output-decimal-marker={,}', 'per-mode=symbol'
)
Assert-ContainsLiteral 'STO-8.4.5' $styleSourcePath @(
    'group-separator={\,}', 'group-minimum-digits=5'
)
Assert-ContainsLiteral 'STO-8.4.5' $rendererSourcePath @("'~' .. command")

# STO-8.5.10: the single-object flag reaches a dedicated global-numbering
# command and the PDF postflight asserts the visible caption number.
Assert-ContainsLiteral 'STO-8.5.10' $templateSourcePath @(
    '$if(susu-single-figure)$', '\SUSUSingleFigureNumbering'
)
Assert-ContainsLiteral 'STO-8.5.10' $postflightSourcePath @(
    "Add-Failure 'STO-8.5.10'"
)

# STO-8.5.11, STO-8.7.10: appendix-local figure/equation number formats.
Assert-ContainsLiteral 'STO-8.5.11' $styleSourcePath @(
    '\renewcommand{\thefigure}{#1.\arabic{figure}}'
)
Assert-ContainsLiteral 'STO-8.7.10' $styleSourcePath @(
    '\renewcommand{\theequation}{#1.\arabic{equation}}'
)

# STO-8.6.7, STO-8.6.12, STO-8.6.13, STO-8.6.15: full-grid long tables,
# numeric policy and the permitted 12 point body size.
Assert-ContainsLiteral 'STO-8.6.7' $rendererSourcePath @('hlines, vlines,')
Assert-ContainsLiteral 'STO-8.6.12' $styleSourcePath @(
    '\RequirePackage{siunitx}', 'output-decimal-marker={,}'
)
Assert-ContainsLiteral 'STO-8.6.13' $rendererSourcePath @(
    'rows={font=\\fontsize{12pt}{14pt}\\selectfont}'
)
Assert-ContainsLiteral 'STO-8.6.15' $styleSourcePath @(
    'group-separator={\,}', 'group-minimum-digits=5'
)

# STO-8.7.6, STO-8.7.13, STO-8.7.17: one equation renderer and controlled
# upright/scalar/vector notation definitions.
Assert-ContainsLiteral 'STO-8.7.6' $rendererSourcePath @(
    '\begin{equation}', '\end{equation}'
)
Assert-ContainsLiteral 'STO-8.7.13' $rendererSourcePath @(
    "if has_class(div, 'equation') then", '\begin{equation}'
)
Assert-ContainsLiteral 'STO-8.7.17' $styleSourcePath @(
    '\newcommand{\scalar}[1]{\symit{#1}}',
    '\newcommand{\greekscalar}[1]{\symup{#1}}'
)
