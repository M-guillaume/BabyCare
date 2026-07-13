class ProjectMember {
  const ProjectMember({
    required this.name,
    required this.role,
    required this.description,
    this.imageAsset,
  });

  final String name;
  final String role;
  final String description;
  final String? imageAsset;
}

// Replace this list with the members of your group.
// imageAsset: put your images in assets/members/ and then set the path,
// e.g. 'assets/members/alice.jpg'
const List<ProjectMember> projectMembers = <ProjectMember>[
  ProjectMember(
    name: 'Anthony Ghiotto',
    role: 'Project supervisor',
    description:
        'Anthony Ghiotto (S\'05-M\'09-SM\'15-F\'26) received the M.Sc. and Ph.D. degrees '
        '(both with distinction) in optics, optoelectronics, and microwave engineering from '
        'the Grenoble Institute of Technology in 2005 and 2008. From 2009 to 2012, he held a '
        'Post-Doctoral Research Associate position at Ecole Polytechnique de Montreal. Since '
        '2012, he has been with ENSEIRB-MATMECA and the IMS laboratory at the University of '
        'Bordeaux, where he is currently an Associate Professor (with Full Professor '
        'habilitation). His research focuses on microwave and millimeter-wave passive and '
        'active circuits in PCB, dielectric waveguides, BiCMOS, and CMOS technologies. He has '
        'received multiple distinctions including the IEEE MTT-S Outstanding Young Engineer '
        'Award (2022) and the IEEE/SEE Leon-Nicolas Brillouin Award (2020).',
  ),
  ProjectMember(
    name: 'Guillaume Malenge',
    role: 'Project lead',
    description:
        'Guillaume Malenge (S\'25) is a second-year engineering student (graduate level) and '
        'an IEEE Student Member. He leads the proposed antenna system project. His academic '
        'interests include wireless technologies, antennas, and RF systems, with a strong '
        'focus on practical implementations.',
  ),
  ProjectMember(
    name: 'Aicha Aissaoui',
    role: 'Project member',
    description:
        'Aicha Aissaoui (S\'25) received her high school diploma with highest honours in '
        '2023. After two years of scientific preparatory classes, she joined the Department '
        'of Electronics at ENSEIRB-MATMECA in Bordeaux. She is currently a final-year '
        'undergraduate student in electronic engineering, serves as a personal tutor, and is '
        'an active member of the school\'s robotics association.',
  ),
  ProjectMember(
    name: 'Matthieu Canellas',
    role: 'Project member',
    description:
        'Matthieu Canellas (S\'25), born in Toulouse, completed his schooling in southern '
        'France and earned his high school diploma with highest honours. He then completed '
        'two years of scientific preparatory studies at Lycee Pierre-de-Fermat, specializing '
        'in Mathematics, Physics, and Engineering Sciences. In 2025, he joined ENSEIRB-'
        'MATMECA (Bordeaux Institute) and became an active member of EIR\'space, contributing '
        'to the design and launch of a small experimental rocket. Passionate about engineering '
        'and automotive technologies, he is also involved in tennis, padel, and weightlifting, '
        'and taught tennis to children for nearly two years.',
  ),
];
