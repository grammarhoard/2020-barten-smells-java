module detectors::RefusedBequest

import Prelude;
import String;
import util::Math;
import lang::java::m3::Core;
import lang::java::m3::AST;
import lang::java::jdt::m3::Core;
import lang::java::jdt::m3::AST;
import metrics::LOC;
import metrics::CC;
import util::Reporting;
import util::Settings;
import util::DataStorage;
import analysis::graphs::Graph;


real avgLOC = 0.0;
real avgCC = 0.0;
real avgAMW = 0.0;
int totalCC = 0;
int totalLOC = 0;
tuple[map[loc, tuple[int wmc, real amw]], int, int, real] complexity = <(), 0,0, 0.0>;
tuple[rel[loc,int], int,int,int,real] linesOfCode = <{}, 0,0,0,0.0>;
map[loc, set[int]] locMap = ();
map[loc, tuple[int wmc, real amw]] ccMap = ();
str prefix = "[RB]";

public void initialize(M3 model) {
	output("<prefix> Initializing RB detector");
	linesOfCode = calculateLOC(model);
	complexity = calculateClassesCC(model);
	
	totalLOC = linesOfCode[1];
	totalCC = complexity[1];
	avgLOC = toReal(linesOfCode[4]);
	avgCC = toReal(complexity[2]);
	locMap = toMap(linesOfCode[0]);
	ccMap = complexity[0];
	avgAMW = complexity[3];
	
	printLinesOfCode(linesOfCode[0], totalLOC, avgLOC);
	printCyclomaticComplexity(ccMap, totalCC, printAll = false);
}

// detect RB using Lanza and Marinescu's metrics 
public rel[loc,loc,bool] detectRB(M3 model, loc project) {	
	// step 1: create AST from project.
	// step 2a: visit classes to see if they have a superclass. If not skip. 
	// Step 2b If they do have a superclass can we access it or is it a default library?
	// Step 3: perform analysis on parent and child. 
	initialize(model);
	output("<prefix> Detector starting for project");
	rel[loc,loc,bool] detectedRBClasses = {};
	rel[loc,loc,bool] RBCandidates = {};
	list[loc] nonTrivialClasses = [];
	bool RB = false;
	
	output("<prefix> Detecting Refused Bequest...");
	// loop through the extended classes. This satisfies the precondition step in 2a and 2b. 
	for(cls <- model.extends, classIsValid(cls)) {
		loc child = cls[0];
		loc parent = cls[1];
		
		bool notSimple = classIsNotSimple(child);
		bool bequest = classIgnoresBequest(model, child, parent);
		if(notSimple) {		
			debug("<child> is not a simple class");
			nonTrivialClasses += child;
		}
		RB = notSimple && bequest;
		tuple[loc,loc,bool] temp =<child, parent, RB>;
		RBCandidates += temp;
		
		if(RB) {
			detectedRBClasses  += temp;
			debug("RB: <temp>");
		}
	}
	output("<prefix> Finished detecting Refused Bequest.");
	

	output("<prefix> Number of RB candidates: <size(RBCandidates)> ");
	output("<prefix> Number of Simple classes: <size(nonTrivialClasses)>");
	output("<prefix> Number of RB positive classes: <size(detectedRBClasses)> ");
	printRB(detectedRBClasses, nonTrivialClasses);
	
	// unfortunately have to save a LARGE amount of data.... might have to refactor.
	storeRBFA(model.fieldAccess);
	//println("<#model.modifiers>");
	
	storeRBMOD(model.modifiers);
	
	storeRBMI(model.methodInvocation);
	storeRBOV(model.methodOverrides);
	
	addProjectToReport(project, totalLOC, totalCC, size(detectedRBClasses));
	
	return detectedRBClasses;
}

// cls must have a superclass. And superclass needs to be accessible within the project. 
bool classIsValid(tuple[loc, loc] classes) {
	return isFile(classes[0])  && isFile(classes[1]);
}

//
bool classIgnoresBequest(M3 model, loc child, loc parent) {
	// for debugging to make sure all the code paths are executed (overrides would be skipped if the first conditon is true otherwise).
	bool protected = parentHasProtectedMembers(model, parent);
	bool childBequest = childRefusesBequest(model, child, parent);
	bool overrides = childHasFewOverrides(model, child);

	return (protected && childBequest) || overrides;
}

bool parentHasProtectedMembers(M3 model, loc parent) { 
	int threshold = getProtectedMemberThreshold();
	// 1. loop through modifiers 2. find matches to parent loc 3. count occurences. 
	int count = 0;
	for (m <- model.modifiers, m[0].parent.path == parent.path && m[1] == \protected()) {
		count += 1;
	}	
	return count > threshold;
}

bool childRefusesBequest(M3 model, loc childLoc, loc parentLoc) { 
	// calculate BUR: Base Class Usage Ratio.
	// "The number of inheritance-specific members used by the measured class,
	// divided by the total number of inheritance-specific members from the base
	// class"
	int usedMembers = 0;
	int parentMembers = 0; 
	
	for (m <- model.modifiers, m[0].parent.path == parentLoc.path && m[1] == \protected()) {
		parentMembers += 1;
	}	
		
	int count = 0;
	for (field <- model.fieldAccess, 
			field[0].parent.path == childLoc.path
			&& field[1].parent.path == parentLoc.path
			&& isFile(field[1])) {
		count += 1;
	}
	
	for (field <- model.methodInvocation, 
			field[0].parent.path == childLoc.path 
			&& field[1].parent.path == parentLoc.path
			&& isFile(field[1])) {		
		count += 1;
	}
		
	real ratio = 0.0;
	// prevent div/0 parent may genuinely be 0. 
	if (parentMembers > 0) {
		ratio = toReal(count) / toReal(parentMembers);
	} 
		
	bool condition = ratio < 0.3333;
	debug("<childLoc> refuses bequest: <condition>, <ratio>");
	return condition;
}

bool childHasFewOverrides(M3 model, loc child) { 
	int threshold = getBequestOverrideThreshold();
	str className = child.file; 
	str classPath = child.path;
	rel[loc, loc] overrides = {};
	// loop through overrides
	for (ov <- model.methodOverrides){ 	
		// compare whole path partial names give too many matches especially with certain naming conventions. 
		if(classPath == (ov[0].parent.path)){ 
			// do stuff here 
			overrides += ov; 
			// either filter more here or do it in another loop. 
		}
	}
	bool condition = size(overrides) > threshold;
	debug("[overrides] <child> has more overrides than threshold"); 
	return condition;
} 

// (functional complexity above average || class complexity is not lower than average). && Class size is above average. 
bool classIsNotSimple(loc cls) {
	return (funcComplexityAbvAvg(cls) || classComplexityAbvAvg(cls)) && classSizeAbvAvg(cls);
}

bool funcComplexityAbvAvg(loc cls) {
	checkIfClassHasValue(cls);
	
	bool condition = ccMap[cls].amw > avgAMW;
	debug("Class <cls.file> has an AMW higher than the avg. <ccMap[cls].amw> avg: <avgAMW>");
	
	return condition;
}

bool classComplexityAbvAvg(loc cls) { 
	int clsCC = 0;
	checkIfClassHasValue(cls);
	clsCC = ccMap[cls].wmc;
	
	// debugging
	bool condition = clsCC > avgCC;
	debug("<cls> is more complex than avg: <clsCC> \> <avgCC> ");
	return condition;
}

bool classSizeAbvAvg(loc cls) {
	int clsLOC = 0;
	if (cls in locMap){
		//output("Class already has a loc value <max(locMap[cls])>");
		clsLOC = max(locMap[cls]);
	} else {
		debug("Class size value not found in lines of code");
		clsLOC = calculateLOCFromLocation(cls);
		debug("Calculated loc... <clsLOC>");
	}
	// debugging
	bool condition = clsLOC > avgLOC;
	debug("<cls> is above avg class size: <clsLOC> \> <avgLOC>\n");
	return condition;
}

// some anon classes can have no separate value. if they're missing add them to the map. Not sure if this causes problems by counting some classes twice.
void checkIfClassHasValue(loc cls) {
	if (cls notin ccMap){
		debug("Class was not found in map");
		// calc cc and add to the map.
		ccMap[cls] = calculateCCByLocation(cls);
	}
}

//Strip location to class name. 
str stripLocation(loc location) {
	loc locPath = location.parent; 
	return last(paths);
}

str stripClassToName(loc location) {
	return location.file;
}